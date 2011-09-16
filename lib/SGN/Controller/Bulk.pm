package SGN::Controller::Bulk;
use Moose;
use namespace::autoclean;
use Cache::File;
use Digest::SHA1 qw/sha1_hex/;
use File::Path qw/make_path/;
use CXGN::Page::FormattingHelpers qw/modesel/;

BEGIN { extends 'Catalyst::Controller' }

has cache => (
    isa        => 'Cache::File',
    lazy_build => 1,
    is         => 'ro',
);


sub _build_cache {
    my $self = shift;

    my $app            = $self->_app;
    my $cache_dir      = $app->path_to($app->tempfiles_subdir(qw/cache bulk feature/));

    $app->log->debug("Bulk: creating new cache in $cache_dir");

    return Cache::File->new(
           cache_root       => $cache_dir,
           default_expires  => 'never',
           # TODO: how big can the output of 10K identifiers be?
           size_limit       => 10_000_000,
           removal_strategy => 'Cache::RemovalStrategy::LRU',
           # temporary, until we figure out locking issue
           lock_level       => Cache::File::LOCK_NFS,
          );
};


=head1 NAME

SGN::Controller::Bulk - Bulk Feature Controller

=head1 DESCRIPTION

Catalyst Controller which allows bulk download of features.

=cut

sub bulk_download_stats :Local {
    my ( $self, $c ) = @_;

    my $seqs    = scalar @{$c->stash->{sequences} || ()};
    my $seq_ids = scalar @{$c->stash->{sequence_identifiers} || ()};
    my $stats   = <<STATS;
A total of $seqs out of $seq_ids sequence identifiers were found.
STATS

    $c->stash( bulk_download_stats => $stats );
}

sub bulk_js_menu :Local {
    my ( $self, $c ) = @_;

    my $mode = $c->stash->{bulk_js_menu_mode};
    # define urls of modes
    my @mode_links = (
        [ '/bulk/input.pl?mode=clone_search',    'Clone&nbsp;name<br />(SGN-C)' ],
        [ '/bulk/input.pl?mode=microarray',      'Array&nbsp;spot&nbsp;ID<br />(SGN-S)' ],
        [ '/bulk/input.pl?mode=unigene',         'Unigene&nbsp;ID<br />(SGN-U)' ],
        [ '/bulk/input.pl?mode=bac',             'BACs' ],
        [ '/bulk/input.pl?mode=bac_end',         'BAC&nbsp;ends' ],
        [ '/bulk/input.pl?mode=ftp',             'Full&nbsp;datasets<br />(FTP)' ],
        [ '/bulk/input.pl?mode=unigene_convert', 'Unigene ID Converter<br />(SGN-U)' ],
        [ '/bulk/feature',                       'Features' ],
    );

    ### figure out which mode we're in ###
    my $modenum =
      $mode =~ /clone_search/i    ? 0
    : $mode =~ /array/i           ? 1
    : $mode =~ /unigene_convert/i ? 6
    : $mode =~ /unigene/i         ? 2
    : $mode =~ /bac_end/i         ? 4
    : $mode =~ /bac/i             ? 3
    : $mode =~ /ftp/i             ? 5
    : $mode =~ /feature/i         ? 7
    :                               0;    # clone search is default

    $c->stash( bulk_js_menu => modesel( \@mode_links, $modenum ) );

}

sub bulk_feature :Path('/bulk/feature') :Args(0) {
    my ( $self, $c ) = @_;
    my $mode = $c->req->param('mode') || 'feature';

    $c->stash( bulk_js_menu_mode => $mode );

    $c->forward('bulk_js_menu');

    $c->stash( template => 'bulk.mason');

    # trigger cache creation
    $self->cache->get("");
}

sub bulk_feature_download :Path('/bulk/feature/download') :Args(1) {
    my ( $self, $c, $sha1 ) = @_;

    my $app            = $self->_app;
    my $cache_dir      = $app->path_to($app->tempfiles_subdir(qw/cache bulk feature/));

    $sha1 =~ s/\.(fasta|txt)$//g;

    my $seqs = $self->cache->thaw($sha1);

    $c->stash( sequences => $seqs->[1] );

    $c->forward( 'View::SeqIO' );
}

sub bulk_feature_submit :Path('/bulk/feature/submit') :Args(0) {
    my ( $self, $c, $file ) = @_;

    my $req  = $c->req;
    my $ids  = $req->param('ids') || '';
    my $mode = $req->param('mode') || 'feature';

    $c->stash( bulk_js_menu_mode => $mode );

    if( $c->req->param('feature_file') ) {
        my ($upload) = $c->req->upload('feature_file');
        # always append contents of file with newline to form input to
        # prevent smashing identifiers together
        $ids        = "$ids\n" . $upload->slurp if $upload;
    }

    # Must calculate this after looking at file contents
    my $sha1 = sha1_hex($ids);

    unless ($ids) {
        $c->throw_client_error(public_message => 'At least one identifier must be given');
    }

    $c->stash( sequence_identifiers => [ split /\s+/, $ids ] );

    $c->forward('Controller::Sequence', 'fetch_sequences');

    $self->cache->freeze( $sha1 , [ $c->stash->{sequence_identifiers}, $c->stash->{sequences} ] );

    $c->forward('bulk_js_menu');
    $c->forward('bulk_download_stats');

    $c->stash( template          => 'bulk_download.mason', sha1 => $sha1 );
}


=head1 AUTHOR

Jonathan "Duke" Leto

=head1 LICENSE

This library is free software. You can redistribute it and/or modify
it under the same terms as Perl itself.

=cut

__PACKAGE__->meta->make_immutable;

1;
