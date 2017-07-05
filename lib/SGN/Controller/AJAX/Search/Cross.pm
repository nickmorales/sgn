

package SGN::Controller::AJAX::Search::Cross;

use Moose;
use Data::Dumper;
use CXGN::Cross;

BEGIN { extends 'Catalyst::Controller::REST'; }

__PACKAGE__->config(
    default   => 'application/json',
    stash_key => 'rest',
    map       => { 'application/json' => 'JSON', 'text/html' => 'JSON' },
   );

sub search_male_parents :Path('/ajax/search/male_parents') :Args(0){
    my $self = shift;
    my $c = shift;
    my $female_parent= $c->req->param("female_parent");
     print STDERR "Female parent =" . Dumper($female_parent) . "\n";


    my $schema = $c->dbic_schema("Bio::Chado::Schema");
    my $male_parent_typeid = $c->model("Cvterm")->get_cvterm_row($schema, "male_parent", "stock_relationship")->cvterm_id();
    my $female_parent_typeid = $c->model("Cvterm")->get_cvterm_row($schema, "female_parent", "stock_relationship")->cvterm_id();

    my $dbh = $schema->storage->dbh();

    my $q = "SELECT DISTINCT female_parent.stock_id, male_parent.stock_id, male_parent.uniquename FROM stock as female_parent
    INNER JOIN stock_relationship AS stock_relationship1 ON (female_parent.stock_id=stock_relationship1.subject_id)
    AND stock_relationship1.type_id= ? INNER JOIN stock_relationship AS stock_relationship2
    ON (stock_relationship1.object_id=stock_relationship2.object_id) INNER JOIN stock AS male_parent
    ON (male_parent.stock_id=stock_relationship2.subject_id) AND stock_relationship2.type_id= ?
    WHERE female_parent.uniquename= ? ORDER BY male_parent.uniquename ASC";


    my $h = $dbh->prepare($q);
    $h->execute($female_parent_typeid, $male_parent_typeid, $female_parent);

    my @male_parents=();
    while(my ($female_parent_id, $male_parent_id, $male_parent_name) = $h->fetchrow_array()){

      push @male_parents, [$male_parent_name];
    }

    $c->stash->{rest} = {data=>\@male_parents};

}

sub search_cross_info : Path('/ajax/search/cross_info') Args(0) {
    my $self = shift;
    my $c = shift;

    my $female_parent = $c->req->param("female_parent");
    my $male_parent = $c->req->param("male_parent");

    print STDERR "Female parent =" . Dumper($female_parent) . "\n";
    print STDERR "Male parent =" . Dumper($male_parent) . "\n";



    my $schema = $c->dbic_schema("Bio::Chado::Schema");

    #my $cross_search = CXGN::Cross->new({bcs_schema => $schema, female_parent => $female_parent, male_parent=>$male_parent});
    my $result = CXGN::Cross->get_cross_info($schema, $female_parent, $male_parent);
    my @cross_info;
    foreach my $r (@$result){
      print STDERR Dumper $r;

    my ($female_parent_id, $female_parent_name, $male_parent_id, $male_parent_name, $cross_entry_id, $cross_name, $cross_type) = @$r;
	  push @cross_info, [ qq{<a href="/stock/$female_parent_id/view">$female_parent_name</a},
    qq{<a href="/stock/$male_parent_id/view">$male_parent_name</a},
    qq{<a href="/cross/$cross_entry_id">$cross_name</a}, $cross_type];
    print STDERR "Cross info =" . Dumper(@cross_info) . "\n";
  }

  $c->stash->{rest}={ data=> \@cross_info};

}


sub search_all_crosses : Path('/ajax/search/all_crosses') Args(0) {
    my $self = shift;
    my $c = shift;

    my $female_parent = $c->req->param("female_parent");

    my $schema = $c->dbic_schema("Bio::Chado::Schema");

    #my $cross_search = CXGN::Cross->new({bcs_schema => $schema, female_parent => $female_parent});
    my $result = CXGN::Cross->get_cross_info($schema, $female_parent);
    my @cross_info;
    foreach my $r (@$result){
      print STDERR Dumper $r;

    my ($female_parent_id, $female_parent_name, $male_parent_id, $male_parent_name, $cross_entry_id, $cross_name, $cross_type) = @$r;
    push @cross_info, [ qq{<a href="/stock/$female_parent_id/view">$female_parent_name</a},
    qq{<a href="/stock/$male_parent_id/view">$male_parent_name</a},
    qq{<a href="/cross/$cross_entry_id">$cross_name</a}, $cross_type];
    print STDERR "Cross info =" . Dumper(@cross_info) . "\n";
  }

  $c->stash->{rest}={ data=> \@cross_info};

  }


sub search_pedigree_male_parents :Path('/ajax/search/pedigree_male_parents') :Args(0){
    my $self = shift;
    my $c = shift;
    my $pedigree_female_parent= $c->req->param("pedigree_female_parent");

    my $schema = $c->dbic_schema('Bio::Chado::Schema', 'sgn_chado');
    my $male_parent_typeid = $c->model("Cvterm")->get_cvterm_row($schema, 'male_parent', 'stock_relationship')->cvterm_id();
    my $female_parent_typeid = $c->model("Cvterm")->get_cvterm_row($schema, 'female_parent', 'stock_relationship')->cvterm_id();
    my $accession_typeid = $c->model("Cvterm")->get_cvterm_row($schema, 'accession', 'stock_type')->cvterm_id();

    my $dbh = $schema->storage->dbh();

    my $q = "SELECT DISTINCT female_parent.stock_id, male_parent.stock_id, male_parent.uniquename FROM stock as female_parent
    INNER JOIN stock_relationship AS stock_relationship1 ON (female_parent.stock_id=stock_relationship1.subject_id)
    AND stock_relationship1.type_id= ? INNER JOIN stock AS check_type ON (stock_relationship1.object_id=check_type.stock_id)
    AND check_type.type_id = ?
    INNER JOIN stock_relationship AS stock_relationship2 ON (stock_relationship1.object_id=stock_relationship2.object_id) AND stock_relationship2.type_id = ?
    INNER JOIN stock AS male_parent ON (male_parent.stock_id=stock_relationship2.subject_id)
    WHERE female_parent.uniquename= ? ORDER BY male_parent.uniquename ASC";


    my $h = $dbh->prepare($q);
    $h->execute($female_parent_typeid, $accession_typeid, $male_parent_typeid, $pedigree_female_parent);

    my @male_parents=();
    while(my ($female_parent_id, $male_parent_id, $male_parent_name) = $h->fetchrow_array()){

      push @male_parents, [$male_parent_name];
    }

    $c->stash->{rest} = {data=>\@male_parents};

}


sub search_all_progenies : Path('/ajax/search/all_progenies') Args(0) {
    my $self = shift;
    my $c = shift;

    my $pedigree_female_parent = $c->req->param("pedigree_female_parent");
    my $schema = $c->dbic_schema("Bio::Chado::Schema");
    my $female_parent_typeid = $c->model("Cvterm")->get_cvterm_row($schema, 'female_parent', 'stock_relationship')->cvterm_id();
    my $male_parent_typeid = $c->model("Cvterm")->get_cvterm_row($schema, 'male_parent', 'stock_relationship')->cvterm_id();
    my $accession_typeid = $c->model("Cvterm")->get_cvterm_row($schema, 'accession', 'stock_type')->cvterm_id();
    my $dbh = $schema->storage->dbh();

    my $q = "SELECT DISTINCT female_parent.stock_id, female_parent.uniquename, male_parent.stock_id, male_parent.uniquename, progeny.stock_id, progeny.uniquename, stock_relationship1.value
    FROM stock_relationship as stock_relationship1 INNER JOIN stock AS female_parent ON (stock_relationship1.subject_id = female_parent.stock_id)
    INNER JOIN stock AS progeny ON (stock_relationship1.object_id = progeny.stock_id)
    LEFT JOIN stock_relationship AS stock_relationship2 ON (progeny.stock_id = stock_relationship2.object_id)
    INNER JOIN stock AS male_parent ON (stock_relationship2.subject_id = male_parent.stock_id)
    WHERE female_parent.uniquename = ? AND stock_relationship1.type_id = ? AND stock_relationship2.type_id = ? AND progeny.type_id = ?
    ORDER BY male_parent.uniquename";

    my$h = $dbh->prepare($q);
    $h->execute($pedigree_female_parent, $female_parent_typeid, $male_parent_typeid, $accession_typeid);

    my@all_progenies=();
    while (my($female_parent_id, $female_parent_name, $male_parent_id, $male_parent_name, $progeny_id, $progeny_name, $cross_type) = $h->fetchrow_array()){

    push @all_progenies, [ qq{<a href="/stock/$female_parent_id/view">$female_parent_name</a>},
      qq{<a href="/stock/$male_parent_id/view">$male_parent_name</a>},
      qq{<a href="/stock/$progeny_id">$progeny_name</a}, $cross_type];
      print STDERR "All_progenies =" . Dumper(@all_progenies) . "\n";
    }

    $c->stash->{rest}={ data=> \@all_progenies};

    }





1;
