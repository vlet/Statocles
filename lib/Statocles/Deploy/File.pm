package Statocles::Deploy::File;
# ABSTRACT: Deploy a site to a folder on the filesystem

use Statocles::Base 'Class';
with 'Statocles::Deploy';

=attr path

The path to deploy to.

=cut

has path => (
    is => 'ro',
    isa => Dir,
    coerce => Dir->coercion,
    required => 1,
);

=method deploy( FROM_STORE, MESSAGE )

Deploy the site, copying from the given store.

=cut

sub deploy {
    my ( $self, $from_store, $message ) = @_;

    my @files;
    my $iter = $from_store->find_files;
    while ( my $path = $iter->() ) {
        # Git versions before 1.7.4.1 require a relative path to 'git add'
        push @files, $path->relative( "/" )->stringify;

        # XXX Implement a friendlier way to copy files from Stores
        my $in_fh = $from_store->open_file( $path );
        my $out_fh = $self->path->child( $path )->touchpath->openw_raw;
        while ( my $line = <$in_fh> ) {
            $out_fh->print( $line );
        }
    }

    return @files;
}

1;
__END__

=head1 DESCRIPTION

This class allows a site to be deployed to a folder on the filesystem.

This class extends L<Statocles::Store::File|Statocles::Store::File>.

=head1 SEE ALSO

=over 4

=item L<Statocles::Store::File>

=item L<Statocles::Deploy>

=back

