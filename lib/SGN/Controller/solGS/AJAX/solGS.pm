
=head1 NAME

SGN::Controller::solGS::AJAX::solGS - a REST controller class to provide the
backend for objects linked with solgs

=head1 AUTHOR

Isaak Yosief Tecle <iyt2@cornell.edu>

=cut

package SGN::Controller::solGS::AJAX::solGS;

use Moose;


BEGIN { extends 'Catalyst::Controller::REST' }

__PACKAGE__->config(
    default   => 'application/json',
    stash_key => 'rest',
    map       => { 'application/json' => 'JSON', 'text/html' => 'JSON' },
   );



sub solgs_trait_search_autocomplete :  Path('/solgs/ajax/trait/search') : ActionClass('REST') { }

sub solgs_trait_search_autocomplete_GET :Args(0) {
    my ( $self, $c ) = @_;

    my $term = $c->req->param('term');
    
    $term =~ s/(^\s+|\s+)$//g;
    $term =~ s/\s+/ /g;
    my @response_list;

    my $rs = $c->model("solGS::solGS")->search_trait($term);

    while (my $row = $rs->next) {      
        push @response_list, $row->name;
    }

    $c->{stash}->{rest} = \@response_list;
}



###
1;
###
