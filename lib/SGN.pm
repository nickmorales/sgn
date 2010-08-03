package SGN;
use Moose;
use namespace::autoclean;

use Catalyst::Runtime 5.80;
use Catalyst qw/
    -Debug
    ConfigLoader
    Static::Simple
/;


use JSAN::ServerSide;

extends 'Catalyst';

with qw(
        SGN::Role::Site::Config
        SGN::Role::Site::Files
        SGN::Role::Site::DBConnector
        SGN::Role::Site::DBIC
        SGN::Role::Site::Mason
        SGN::Role::Site::SiteFeatures
        SGN::Role::Site::ExceptionHandling
       );


# on startup, if on a dev setup, symlink the static_datasets and
# static_content in the root dir so that
# Catalyst::Plugin::Static::Simple can serve them.  in production,
# these will be served directly by Apache
after 'setup_finalize' => sub {
    my $self = shift;
    unless( $self->config->{production_server} ) {
        my @links = (

            # make symlink for /img
            [ $self->path_to('documents','img'), $self->path_to('img') ],

            # make symlinks for static_content and static_datasets
            ( map [ $self->config->{$_.'_path'} =>  File::Spec->catfile( $self->config->{root}, $self->config->{$_.'_url'} ) ],
                  qw( static_content static_datasets )
            ),

           );

        for my $link (@links) {
            unlink $link->[1];
            symlink( $link->[0], $link->[1] )
                or die "$! symlinking $link->[0] => $link->[1]";
        }
    }
};


# Start the application
__PACKAGE__->setup();


=head2 new_jsan

  Usage: $c->new_jsan
  Desc : instantiates a new L<JSAN::ServerSide> object with the
         correct javascript dir and uri prefix for site-global javascript
  Args : none
  Ret  : a new L<JSAN::ServerSide> object

=cut
has _jsan_params => ( is => 'ro', isa => 'HashRef', lazy_build => 1 );
sub _build__jsan_params {
  my ( $self ) = @_;
  my $js_dir = $self->path_to( $self->get_conf('global_js_lib') );
  -d $js_dir or die "configured global_js_dir '$js_dir' does not exist!\n";

  return { js_dir     => "$js_dir",
	   uri_prefix => '/js',
	 };
}
sub new_jsan {
    JSAN::ServerSide->new( %{ shift->_jsan_params } );
}

=head2 js_import_uris

  Usage: $c->js_import_uris('CXGN.Effects','CXGN.Phenome.Locus');
  Desc : generate a list of L<URI> objects to import the given
         JavaScript modules, with dependencies.
  Args : list of desired modules
  Ret  : list of L<URI> objects

=cut

sub js_import_uris {
    my $self = shift;
    my $j = $self->new_jsan;
    my @urls = @_;
    $j->add(my $m = $_) for @urls;
    return [ $j->uris ];
}

=head1 NAME

SGN - Catalyst-based application to run the SGN website.

=head1 SYNOPSIS

    script/sgn_server.pl

=head1 DESCRIPTION

[enter your description here]

=head1 SEE ALSO

L<SGN::Controller::Root>, L<Catalyst>

=head1 AUTHOR

Robert Buels,,,

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

1;
