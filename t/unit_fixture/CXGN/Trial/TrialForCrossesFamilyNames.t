
use strict;

use Test::More;
use lib 't/lib';
use SGN::Test::Fixture;
use JSON::Any;
use Data::Dumper;

my $fix = SGN::Test::Fixture->new();

is(ref($fix->config()), "HASH", 'hashref check');

BEGIN {use_ok('CXGN::Trial::TrialCreate');}
BEGIN {use_ok('CXGN::Trial::TrialLayout');}
BEGIN {use_ok('CXGN::Trial::TrialDesign');}
BEGIN {use_ok('CXGN::Trial::TrialLayoutDownload');}
BEGIN {use_ok('CXGN::Trial::TrialLookup');}
ok(my $schema = $fix->bcs_schema);
ok(my $phenome_schema = $fix->phenome_schema);
ok(my $dbh = $fix->dbh);

# create crosses and family_names for the trial
my $cross_type_id = SGN::Model::Cvterm->get_cvterm_row($schema, "cross", "stock_type")->cvterm_id();
my $family_name_type_id = SGN::Model::Cvterm->get_cvterm_row($schema, "family_name", "stock_type")->cvterm_id();

my @cross_ids;
for (my $i = 1; $i <= 5; $i++) {
    push(@cross_ids, "cross_for_trial".$i);
}

my @family_names;
for (my $i = 1; $i <= 5; $i++) {
    push(@family_names, "family_name_for_trial".$i);
}

ok(my $organism = $schema->resultset("Organism::Organism")
    ->find_or_create( {
       genus => 'Test_genus',
       species => 'Test_genus test_species',
	}, ));

foreach my $cross_id (@cross_ids) {
    my $cross_for_trial = $schema->resultset('Stock::Stock')
	->create({
	    organism_id => $organism->organism_id,
	    name       => $cross_id,
	    uniquename => $cross_id,
	    type_id     => $cross_type_id,
    });
};

foreach my $family_name (@family_names) {
    my $family_name_for_trial = $schema->resultset('Stock::Stock')
	->create({
	    organism_id => $organism->organism_id,
	    name       => $family_name,
	    uniquename => $family_name,
	    type_id     => $family_name_type_id,
	});
};

# create trial with cross stock type
ok(my $cross_trial_design = CXGN::Trial::TrialDesign->new(), "create trial design object");
ok($cross_trial_design->set_trial_name("cross_to_trial1"), "set trial name");
ok($cross_trial_design->set_stock_list(\@cross_ids), "set stock list");
ok($cross_trial_design->set_plot_start_number(1), "set plot start number");
ok($cross_trial_design->set_plot_number_increment(1), "set plot increment");
ok($cross_trial_design->set_number_of_blocks(2), "set block number");
ok($cross_trial_design->set_design_type("RCBD"), "set design type");
ok($cross_trial_design->calculate_design(), "calculate design");
ok(my $cross_design = $cross_trial_design->get_design(), "retrieve design");

my $preliminary_trial_cvterm_id = SGN::Model::Cvterm->get_cvterm_row($schema, 'Preliminary Yield Trial', 'project_type')->cvterm_id();

ok(my $crosses_trial_create = CXGN::Trial::TrialCreate->new({
    chado_schema => $schema,
    dbh => $dbh,
    user_name => "janedoe", #not implemented
    design => $cross_design,
    program => "test",
    trial_year => "2020",
    trial_description => "test description",
    trial_location => "test_location",
    trial_name => "cross_to_trial1",
    trial_type=>$preliminary_trial_cvterm_id,
    design_type => "RCBD",
    operator => "janedoe",
    trial_stock_type => "cross"
}), "create trial object");

my $crosses_trial_save = $crosses_trial_create->save_trial();
ok($crosses_trial_save->{'trial_id'}, "save trial");

ok(my $crosses_trial_lookup = CXGN::Trial::TrialLookup->new({
    schema => $schema,
    trial_name => "cross_to_trial1",
}), "create trial lookup object");
ok(my $crosses_trial = $crosses_trial_lookup->get_trial());
ok(my $cross_trial_id = $crosses_trial->project_id());
ok(my $cross_trial_layout = CXGN::Trial::TrialLayout->new({
    schema => $schema,
    trial_id => $cross_trial_id,
    experiment_type => 'field_layout'
}), "create trial layout object");

my $cross_trial_design = $cross_trial_layout->get_design();
my @cross_plot_nums;
my @crosses;
my @cross_block_nums;
my @cross_plot_names;

# note:cross and family_name stock types use the same accession_name key as accession stock type in trial design
foreach my $cross_plot_num (keys %$cross_trial_design) {
    push @cross_plot_nums, $cross_plot_num;
    push @crosses, $cross_trial_design->{$cross_plot_num}->{'accession_name'};
    push @cross_block_nums, $cross_trial_design->{$cross_plot_num}->{'block_number'};
    push @cross_plot_names, $cross_trial_design->{$cross_plot_num}->{'plot_name'};

}
@cross_plot_nums = sort @cross_plot_nums;
@crosses = sort @crosses;
@cross_block_nums = sort @cross_block_nums;

is_deeply(\@cross_plot_nums, [
        '1',
        '10',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9'
    ], "check cross plot numbers");

is_deeply(\@crosses, [
        'cross_for_trial1',
        'cross_for_trial1',
        'cross_for_trial2',
        'cross_for_trial2',
        'cross_for_trial3',
        'cross_for_trial3',
        'cross_for_trial4',
        'cross_for_trial4',
        'cross_for_trial5',
        'cross_for_trial5'
    ], "check cross unique ids");

is_deeply(\@cross_block_nums, [
        '1',
        '1',
        '1',
        '1',
        '1',
        '2',
        '2',
        '2',
        '2',
        '2'
    ], "check cross block numbers");

is(scalar@cross_plot_names, 10);

my $cross_trial_type = CXGN::Trial->new({ bcs_schema => $schema, trial_id => $cross_trial_id });
my $cross_trial_stock_type = $cross_trial_type->get_trial_stock_type();
is($cross_trial_stock_type, 'cross');

# create trial with family_name stock type
ok(my $fam_trial_design = CXGN::Trial::TrialDesign->new(), "create trial design object");
ok($fam_trial_design->set_trial_name("family_name_to_trial1"), "set trial name");
ok($fam_trial_design->set_stock_list(\@family_names), "set stock list");
ok($fam_trial_design->set_plot_start_number(1), "set plot start number");
ok($fam_trial_design->set_plot_number_increment(1), "set plot increment");
ok($fam_trial_design->set_number_of_reps(2), "set rep number");
ok($fam_trial_design->set_design_type("CRD"), "set design type");
ok($fam_trial_design->calculate_design(), "calculate design");
ok(my $fam_design = $fam_trial_design->get_design(), "retrieve design");

ok(my $fam_trial_create = CXGN::Trial::TrialCreate->new({
    chado_schema => $schema,
    dbh => $dbh,
    user_name => "janedoe", #not implemented
    design => $fam_design,
    program => "test",
    trial_year => "2020",
    trial_description => "test description",
    trial_location => "test_location",
    trial_name => "family_name_to_trial1",
    trial_type=>$preliminary_trial_cvterm_id,
    design_type => "CRD",
    operator => "janedoe",
    trial_stock_type => "family_name"
}), "create trial object");

my $fam_save = $fam_trial_create->save_trial();
ok($fam_save->{'trial_id'}, "save trial");
ok(my $fam_trial_lookup = CXGN::Trial::TrialLookup->new({
    schema => $schema,
    trial_name => "family_name_to_trial1",
}), "create trial lookup object");
ok(my $fam_trial = $fam_trial_lookup->get_trial());
ok(my $fam_trial_id = $fam_trial->project_id());
ok(my $fam_trial_layout = CXGN::Trial::TrialLayout->new({
    schema => $schema,
    trial_id => $fam_trial_id,
    experiment_type => 'field_layout'
}), "create trial layout object");

my $fam_trial_design = $fam_trial_layout->get_design();
my @fam_plot_nums;
my @family_names;
my @fam_rep_nums;
my @fam_plot_names;

# note:cross and family_name stock types use the same accession_name key as accession stock type in trial design
foreach my $fam_plot_num (keys %$fam_trial_design) {
    push @fam_plot_nums, $fam_plot_num;
    push @family_names, $fam_trial_design->{$fam_plot_num}->{'accession_name'};
    push @fam_rep_nums, $fam_trial_design->{$fam_plot_num}->{'rep_number'};
    push @fam_plot_names, $fam_trial_design->{$fam_plot_num}->{'plot_name'};
}
@fam_plot_nums = sort @fam_plot_nums;
@family_names = sort @family_names;
@fam_rep_nums = sort @fam_rep_nums;

is_deeply(\@fam_plot_nums, [
        '1',
        '10',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9'
    ], "check family_name plot numbers");

is_deeply(\@family_names, [
        'family_name_for_trial1',
        'family_name_for_trial1',
        'family_name_for_trial2',
        'family_name_for_trial2',
        'family_name_for_trial3',
        'family_name_for_trial3',
        'family_name_for_trial4',
        'family_name_for_trial4',
        'family_name_for_trial5',
        'family_name_for_trial5'
    ], "check family names");

is_deeply(\@fam_rep_nums, [
        '1',
        '1',
        '1',
        '1',
        '1',
        '2',
        '2',
        '2',
        '2',
        '2'
    ], "check fam rep numbers");

is(scalar@fam_plot_names, 10);

my $fam_trial_type = CXGN::Trial->new({ bcs_schema => $schema, trial_id => $fam_trial_id });
my $fam_trial_stock_type = $fam_trial_type->get_trial_stock_type();
is($fam_trial_stock_type, 'family_name');

done_testing();
