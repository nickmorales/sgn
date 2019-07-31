
=head1 NAME

CXGN::Trial - factory object for project entries (phenotyping trials, genotyping trials, crossing trials, and analyses

=head1 DESCRIPTION

my $trial = CXGN::Trial->new( { bcs_schema => $schema, ... , trial_id => $trial_id });

If $trial_id is a phenotyping trial, the type of object returned will be CXGN::PhenotypingTrial.

If $trial_id is a genotyping trial, the type of object returned will be CXGN::GenotypingTrial.

If $trial_id is a crossing trial, the type of object returned will be CXGN::CrossingTrial.

If $trial_id is an analysis, the type of object returned will be CXGN::Analysis.

(you get the idea).

Inheritance structure of Trial objects:

CXGN::Trial - Factory object (for backwards compatibility)

CXGN::Project
|
---CXGN::PhenotypingTrial
|  |
|  ---CXGN::GenotypingTrial
|  |
|  ---CXGN::CrossingTrial
|
---CXGN::Analysis

=head1 AUTHOR

Lukas Mueller <lam87@cornell.edu>

Based on work by the entire group :-)

=cut
    
package CXGN::Trial;

use CXGN::PhenotypingTrial;
use CXGN::GenotypingTrial;
use CXGN::CrossingTrial;
use CXGN::Analysis;
use CXGN::ManagementFactor;
use CXGN::GenotypeDataProject;
use Data::Dumper;

sub new {
    my $class = shift;
    my $args = shift;
    my $schema = $args->{bcs_schema};
    my $trial_id = $args->{trial_id};

    my $trial_rs = $schema->resultset("Project::Projectprop")->search( { project_id => $trial_id },{ join => 'type' });

    my $object;
    if ($trial_id && $trial_rs->count() == 0) {
        $object = CXGN::PhenotypingTrial->new($args);
    }

    while (my $trial_row = $trial_rs->next()) { 
        my $name = $trial_row->type()->name();
        my $val = $trial_row->value();
        #print STDERR Dumper [$name, $val];
        if ($val eq "genotyping_plate") {
            $object = CXGN::GenotypingTrial->new($args);
        }
        elsif ($name eq "crossing_trial") {
            $object = CXGN::CrossingTrial->new($args);
        }
        elsif ($name eq "analysis") {
            $object = CXGN::Analysis->new($args);
        }
        elsif ($val eq "treatment") {
            $object = CXGN::ManagementFactor->new($args);
        }
        elsif ($val eq "genotype_data_project") {
            $object = CXGN::GenotypeDataProject->new($args);
        }
        else {
            $object = CXGN::PhenotypingTrial->new($args);
        }
    }
    return $object;
}

=head2 class method get_all_locations()

 Usage:        my $locations = CXGN::Trial::get_all_locations($schema)
 Desc:
 Ret:
 Args:
 Side Effects:
 Example:

=cut

sub get_all_locations {
    my $schema = shift;
	my $location_id = shift;
    my @locations;

	my %search_params;
	if ($location_id){
		$search_params{'nd_geolocation_id'} = $location_id;
	}

    my $loc = $schema->resultset('NaturalDiversity::NdGeolocation')->search( \%search_params, {order_by => { -asc => 'nd_geolocation_id' }} );
    while (my $s = $loc->next()) {
        my $loc_props = $schema->resultset('NaturalDiversity::NdGeolocationprop')->search( { nd_geolocation_id => $s->nd_geolocation_id() }, {join=>'type', '+select'=>['me.value', 'type.name'], '+as'=>['value', 'cvterm_name'] } );

		my %attr;
        $attr{'geodetic datum'} = $s->geodetic_datum();

        my $country = '';
        my $country_code = '';
        my $location_type = '';
        my $abbreviation = '';
        my $address = '';

        while (my $sp = $loc_props->next()) {
            if ($sp->get_column('cvterm_name') eq 'country_name') {
                $country = $sp->get_column('value');
            } elsif ($sp->get_column('cvterm_name') eq 'country_code') {
                $country_code = $sp->get_column('value');
            } elsif ($sp->get_column('cvterm_name') eq 'location_type') {
                $location_type = $sp->get_column('value');
            } elsif ($sp->get_column('cvterm_name') eq 'abbreviation') {
                $abbreviation = $sp->get_column('value');
            } elsif ($sp->get_column('cvterm_name') eq 'geolocation address') {
                $address = $sp->get_column('value');
            } else {
                $attr{$sp->get_column('cvterm_name')} = $sp->get_column('value') ;
            }
        }

        push @locations, [$s->nd_geolocation_id(), $s->description(), $s->latitude(), $s->longitude(), $s->altitude(), $country, $country_code, \%attr, $location_type, $abbreviation, $address],
    }

    return \@locations;
}

# CLASS METHOD!

=head2 class method get_all_project_types()

 Usage:        my @cvterm_ids = CXGN::Trial::get_all_project_types($schema)
 Desc:
 Ret:
 Args:
 Side Effects:
 Example:

=cut

sub get_all_project_types {
    ##my $class = shift;
    my $schema = shift;
    my $project_type_cv_id = $schema->resultset('Cv::Cv')->find( { name => 'project_type' } )->cv_id();
    my $rs = $schema->resultset('Cv::Cvterm')->search( { cv_id=> $project_type_cv_id }, {order_by=>'me.cvterm_id'} );
    my @cvterm_ids;
    if ($rs->count() > 0) {
	@cvterm_ids = map { [ $_->cvterm_id(), $_->name(), $_->definition ] } ($rs->all());
    }
    return @cvterm_ids;
}


=head2 function get_all_phenotype_metadata($schema, $n)

 Note:         Class method!
 Usage:        CXGN::Trial->get_phenotype_metadata($schema, 100);
 Desc:         retrieves maximally $n metadata.md_file entries for the any trial . These entries are created during StorePhenotypes.
 Ret:
 Args:
 Side Effects:
 Example:

=cut

sub get_all_phenotype_metadata {
    my $class = shift;
    my $schema = shift;
    my $n = shift || 200;
    my @file_array;
    my %file_info;
    my $q = "SELECT file_id, m.create_date, p.sp_person_id, p.username, basename, dirname, filetype FROM nd_experiment_project JOIN nd_experiment_phenotype USING(nd_experiment_id) JOIN phenome.nd_experiment_md_files ON (nd_experiment_phenotype.nd_experiment_id=nd_experiment_md_files.nd_experiment_id) LEFT JOIN metadata.md_files using(file_id) LEFT JOIN metadata.md_metadata as m using(metadata_id) LEFT JOIN sgn_people.sp_person as p ON (p.sp_person_id=m.create_person_id) WHERE m.obsolete = 0 and NOT (metadata.md_files.filetype='generated from plot from plant phenotypes') and NOT (metadata.md_files.filetype='direct phenotyping') ORDER BY file_id ASC LIMIT $n";
    my $h = $schema->storage()->dbh()->prepare($q);
    $h->execute();
    
    while (my ($file_id, $create_date, $person_id, $username, $basename, $dirname, $filetype) = $h->fetchrow_array()) {
	$file_info{$file_id} = [$file_id, $create_date, $person_id, $username, $basename, $dirname, $filetype];
    }
    foreach (keys %file_info){
	push @file_array, $file_info{$_};
    }
    return \@file_array;
}

1;

