package Statocles::Site;
# ABSTRACT: An entire, configured website

use Statocles::Base 'Class';
use Scalar::Util qw( blessed );
use Mojo::URL;
use Mojo::DOM;
use Mojo::Log;

=attr title

The site title, used in templates.

=cut

has title => (
    is => 'ro',
    isa => Str,
);

=attr base_url

The base URL of the site, including protocol and domain. Used mostly for feeds.

This can be overridden by L<base_url in Deploy|Statocles::Deploy/base_url>.

=cut

has base_url => (
    is => 'ro',
    isa => Str,
);

=attr theme

The L<theme|Statocles::Theme> for this site. All apps share the same theme.

=cut

has theme => (
    is => 'ro',
    isa => Theme,
    required => 1,
    coerce => Theme->coercion,
);

=attr apps

The applications in this site. Each application has a name
that can be used later.

=cut

has apps => (
    is => 'ro',
    isa => HashRef[InstanceOf['Statocles::App']],
    default => sub { {} },
);

=attr index

The application to use as the site index. The application's individual index()
method will be called to get the index page.

=cut

has index => (
    is => 'ro',
    isa => Str,
    default => sub { '' },
);

=attr nav

Named navigation lists. A hash of arrays of hashes with the following keys:

    title - The title of the link
    href - The href of the link

The most likely name for your navigation will be C<main>. Navigation names
are defined by your L<theme|Statocles::Theme>. For example:

    {
        main => [
            {
                title => 'Blog',
                href => '/blog/index.html',
            },
            {
                title => 'Contact',
                href => '/contact.html',
            },
        ],
    }

=cut

has _nav => (
    is => 'ro',
    isa => LinkHash,
    coerce => LinkHash->coercion,
    default => sub { {} },
    init_arg => 'nav',
);

=attr build_store

The L<store|Statocles::Store> object to use for C<build()>. This is a workspace
and will be rebuilt often, using the C<build> and C<daemon> commands. This is
also the store the C<daemon> command reads to serve the site.

=cut

has build_store => (
    is => 'ro',
    isa => Store,
    required => 1,
    coerce => Store->coercion,
);

=attr deploy

The L<deploy object|Statocles::Deploy> to use for C<deploy()>. This is
intended to be the production deployment of the site. A build gets promoted to
production by using the C<deploy> command.

=cut

has _deploy => (
    is => 'ro',
    isa => ConsumerOf['Statocles::Deploy'],
    required => 1,
    init_arg => 'deploy',
    coerce => sub {
        if ( ( blessed $_[0] && $_[0]->isa( 'Path::Tiny' ) ) || !ref $_[0] ) {
            require Statocles::Deploy::File;
            return Statocles::Deploy::File->new(
                path => $_[0],
            );
        }
        return $_[0];
    },
);

=attr data

A hash of arbitrary data available to theme templates. This is a good place to
put extra structured data like social network links or make easy customizations
to themes like header image URLs.

=cut

has data => (
    is => 'ro',
    isa => HashRef,
    default => sub { {} },
);

=attr log

A L<Mojo::Log> object to write logs to. Defaults to STDERR.

=cut

has log => (
    is => 'ro',
    isa => InstanceOf['Mojo::Log'],
    lazy => 1,
    default => sub {
        Mojo::Log->new( level => 'info' );
    },
);

# The current deploy we're writing to
has _write_deploy => (
    is => 'rw',
    isa => ConsumerOf['Statocles::Deploy'],
    clearer => '_clear_write_deploy',
);

=method BUILD

Register this site as the global site.

=cut

sub BUILD {
    my ( $self ) = @_;
    $Statocles::SITE = $self;
    for my $app ( values %{ $self->apps } ) {
        $app->site( $self );
    }
}

=method app( name )

Get the app with the given C<name>.

=cut

sub app {
    my ( $self, $name ) = @_;
    return $self->apps->{ $name };
}

=method nav( name )

Get the list of links for the given nav. Each link is a L<Statocles::Link> object.

    title - The title of the link
    href - The href of the link

If the named nav does not exist, returns an empty list.

=cut

sub nav {
    my ( $self, $name ) = @_;
    return $self->_nav->{ $name } ? @{ $self->_nav->{ $name } } : ();
}

=method build

Build the site in its build location

=cut

sub build {
    my ( $self ) = @_;

    my $store = $self->build_store;
    my $apps = $self->apps;
    my @pages;
    my %args = (
        site => $self,
    );

    # Collect all the pages for this site
    for my $app_name ( keys %{ $apps } ) {
        my $app = $apps->{$app_name};

        my @app_pages = $app->pages;
        if ( $self->index eq $app_name ) {

            die sprintf 'ERROR: Index app "%s" did not generate any pages' . "\n", $self->index
                unless @app_pages;

            # Rename the app's page so that we don't get two pages with identical
            # content, which is bad for SEO
            $app_pages[0]->path( '/index.html' );
        }

        push @pages, @app_pages;
    }

    # Rewrite page content to add base URL
    my $base_url = $self->base_url;
    if ( $self->_write_deploy ) {
        $base_url = $self->_write_deploy->base_url || $base_url;
    }
    my $base_path = Mojo::URL->new( $base_url )->path;

    for my $page ( @pages ) {
        my $content = $page->render( %args );

        if ( !ref $content ) {
            if ( $base_path =~ /\S/ ) {
                my $dom = Mojo::DOM->new( $content );
                for my $attr ( qw( src href ) ) {
                    for my $el ( $dom->find( "[$attr]" )->each ) {
                        my $url = $el->attr( $attr );
                        next unless $url =~ m{^/};
                        $el->attr( $attr, join "", $base_path, $url );
                    }
                }
                $content = $dom->to_string;
            }
        }

        $store->write_file( $page->path, $content );
    }

    # Build the sitemap.xml
    # html files only
    my @indexed_pages = grep { $_->path =~ /[.]html?$/ } @pages;
    my $tmpl = $self->theme->template( site => 'sitemap.xml' );
    $store->write_file( 'sitemap.xml', $tmpl->render( site => $self, pages => \@indexed_pages ) );

    # robots.txt is the best way for crawlers to automatically discover sitemap.xml
    # We should do more with this later...
    my $robots_tmpl = $self->theme->template( site => 'robots.txt' );
    $store->write_file( 'robots.txt', $robots_tmpl->render( site => $self ) );

    # Add the theme
    my $theme_iter = $self->theme->store->find_files();
    while ( my $theme_file = $theme_iter->() ) {
        my $fh = $self->theme->store->open_file( $theme_file );
        $store->write_file( Path::Tiny->new( 'theme', $theme_file ), $fh );
    }
}

=method deploy

Deploy the site to its destination.

=cut

sub deploy {
    my ( $self ) = @_;
    $self->_write_deploy( $self->_deploy );
    $self->build;
    $self->_deploy->deploy( $self->build_store );
    $self->_clear_write_deploy;
}

=method url( path )

Get the full URL to the given path by prepending the C<base_url>.

=cut

sub url {
    my ( $self, $path ) = @_;
    my $base    = $self->_write_deploy && $self->_write_deploy->base_url
                ? $self->_write_deploy->base_url
                : $self->base_url;
    # Remove the / from both sides of the join so we don't double up
    $base =~ s{/$}{};
    $path =~ s{^/}{};
    return join "/", $base, $path;
}

1;
__END__

=head1 SYNOPSIS

    my $site = Statocles::Site->new(
        title => 'My Site',
        nav => [
            { title => 'Home', href => '/' },
            { title => 'Blog', href => '/blog' },
        ],
        apps => {
            blog => Statocles::App::Blog->new( ... ),
        },
    );

    $site->deploy;

=head1 DESCRIPTION

A Statocles::Site is a collection of L<applications|Statocles::App>.

