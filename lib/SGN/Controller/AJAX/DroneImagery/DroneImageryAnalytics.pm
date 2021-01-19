
=head1 NAME

SGN::Controller::AJAX::DroneImagery::DroneImageryAnalytics - a REST controller class to provide the
functions for drone imagery analytics

=head1 DESCRIPTION

=head1 AUTHOR

=cut

package SGN::Controller::AJAX::DroneImagery::DroneImageryAnalytics;

use Moose;
use Data::Dumper;
use LWP::UserAgent;
use JSON;
use SGN::Model::Cvterm;
use DateTime;
use CXGN::UploadFile;
use SGN::Image;
use CXGN::DroneImagery::ImagesSearch;
use URI::Encode qw(uri_encode uri_decode);
use File::Basename qw | basename dirname|;
use File::Slurp qw(write_file);
use File::Temp 'tempfile';
use CXGN::Calendar;
use Image::Size;
use Text::CSV;
use CXGN::Phenotypes::StorePhenotypes;
use CXGN::Phenotypes::PhenotypeMatrix;
use CXGN::BrAPI::FileResponse;
use CXGN::Onto;
use R::YapRI::Base;
use R::YapRI::Data::Matrix;
use CXGN::Tag;
use CXGN::DroneImagery::ImageTypes;
use Time::Piece;
use POSIX;
use Math::Round;
use Parallel::ForkManager;
use CXGN::NOAANCDC;
use CXGN::BreederSearch;
use CXGN::Phenotypes::SearchFactory;
use CXGN::BreedersToolbox::Accessions;
use CXGN::Genotype::GRM;
use CXGN::Pedigree::ARM;
use CXGN::AnalysisModel::SaveModel;
use CXGN::AnalysisModel::GetModel;
use Math::Polygon;
use Math::Trig;
use List::MoreUtils qw(first_index);
use List::Util qw(sum);
use Scalar::Util qw(looks_like_number);
use SGN::Controller::AJAX::DroneImagery::DroneImagery;
use Storable qw(dclone);
use Statistics::Descriptive;
#use Inline::Python;

BEGIN { extends 'Catalyst::Controller::REST' }

__PACKAGE__->config(
    default   => 'application/json',
    stash_key => 'rest',
    map       => { 'application/json' => 'JSON', 'text/html' => 'JSON'  },
);

sub drone_imagery_calculate_analytics : Path('/api/drone_imagery/calculate_analytics') : ActionClass('REST') { }
sub drone_imagery_calculate_analytics_POST : Args(0) {
    my $self = shift;
    my $c = shift;
    print STDERR Dumper $c->req->params();
    my $schema = $c->dbic_schema("Bio::Chado::Schema");
    my $people_schema = $c->dbic_schema("CXGN::People::Schema");
    my ($user_id, $user_name, $user_role) = _check_user_login($c);

    my $statistics_select = $c->req->param('statistics_select');
    my $analytics_select = $c->req->param('analytics_select');

    my $field_trial_id_list = $c->req->param('field_trial_id_list') ? decode_json $c->req->param('field_trial_id_list') : [];
    my $field_trial_id_list_string = join ',', @$field_trial_id_list;
    
    if (scalar(@$field_trial_id_list) != 1) {
        $c->stash->{rest} = { error => "Please select one field trial!"};
        return;
    }

    my $trait_id_list = $c->req->param('observation_variable_id_list') ? decode_json $c->req->param('observation_variable_id_list') : [];
    my $compute_relationship_matrix_from_htp_phenotypes = $c->req->param('relationship_matrix_type') || 'genotypes';
    my $compute_relationship_matrix_from_htp_phenotypes_type = $c->req->param('htp_pheno_rel_matrix_type');
    my $compute_relationship_matrix_from_htp_phenotypes_time_points = $c->req->param('htp_pheno_rel_matrix_time_points');
    my $compute_relationship_matrix_from_htp_phenotypes_blues_inversion = $c->req->param('htp_pheno_rel_matrix_blues_inversion');
    my $compute_from_parents = $c->req->param('compute_from_parents') eq 'yes' ? 1 : 0;
    my $include_pedgiree_info_if_compute_from_parents = $c->req->param('include_pedgiree_info_if_compute_from_parents') eq 'yes' ? 1 : 0;
    my $use_parental_grms_if_compute_from_parents = $c->req->param('use_parental_grms_if_compute_from_parents') eq 'yes' ? 1 : 0;
    my $use_area_under_curve = $c->req->param('use_area_under_curve') eq 'yes' ? 1 : 0;
    my $protocol_id = $c->req->param('protocol_id');
    my $tolparinv = $c->req->param('tolparinv');
    my $legendre_order_number = $c->req->param('legendre_order_number');
    my $permanent_environment_structure = $c->req->param('permanent_environment_structure');
    my $permanent_environment_structure_phenotype_correlation_traits = decode_json $c->req->param('permanent_environment_structure_phenotype_correlation_traits');

    my $minimization_genetic_sum_threshold = $c->req->param('genetic_minimization_threshold') || '0.000001';
    my $minimization_env_sum_threshold = $c->req->param('env_minimization_threshold') || '0.000001';
    my $env_simulation = $c->req->param('env_simulation');

    my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
    my $tmp_stats_dir = $shared_cluster_dir_config."/tmp_drone_statistics";
    mkdir $tmp_stats_dir if ! -d $tmp_stats_dir;
    my ($grm_rename_tempfile_fh, $grm_rename_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    $grm_rename_tempfile .= '.GRM';
    my ($minimization_iterations_tempfile_fh, $minimization_iterations_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);

    my $dir = $c->tempfiles_subdir('/tmp_drone_statistics');
    my $minimization_iterations_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
    $minimization_iterations_tempfile_string .= '.png';
    my $minimization_iterations_figure_tempfile = $c->config->{basepath}."/".$minimization_iterations_tempfile_string;

    my $env_effects_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
    $env_effects_figure_tempfile_string .= '.png';
    my $env_effects_figure_tempfile = $c->config->{basepath}."/".$env_effects_figure_tempfile_string;

    my $blupf90_solutions_tempfile;
    my $yhat_residual_tempfile;
    my $grm_file;

    my $field_trial_design;

    eval {

        foreach my $field_trial_id (@$field_trial_id_list) {
            my $field_trial_design_full = CXGN::Trial->new({bcs_schema => $schema, trial_id=>$field_trial_id})->get_layout()->get_design();
            while (my($plot_number, $plot_obj) = each %$field_trial_design_full) {
                my $plot_number_unique = $field_trial_id."_".$plot_number;
                $field_trial_design->{$plot_number_unique} = {
                    stock_name => $plot_obj->{accession_name},
                    block_number => $plot_obj->{block_number},
                    col_number => $plot_obj->{col_number},
                    row_number => $plot_obj->{row_number},
                    plot_name => $plot_obj->{plot_name},
                    plot_number => $plot_number_unique,
                    rep_number => $plot_obj->{rep_number},
                    is_a_control => $plot_obj->{is_a_control}
                };
            }
        }

        my $drone_run_related_time_cvterms_json_cvterm_id = SGN::Model::Cvterm->get_cvterm_row($schema, 'drone_run_related_time_cvterms_json', 'project_property')->cvterm_id();
        my $drone_run_field_trial_project_relationship_type_id_cvterm_id = SGN::Model::Cvterm->get_cvterm_row($schema, 'drone_run_on_field_trial', 'project_relationship')->cvterm_id();
        my $drone_run_band_drone_run_project_relationship_type_id_cvterm_id = SGN::Model::Cvterm->get_cvterm_row($schema, 'drone_run_band_on_drone_run', 'project_relationship')->cvterm_id();
        my $drone_run_time_q = "SELECT drone_run_project.project_id, project_relationship.object_project_id, projectprop.value
            FROM project AS drone_run_band_project
            JOIN project_relationship AS drone_run_band_rel ON (drone_run_band_rel.subject_project_id = drone_run_band_project.project_id AND drone_run_band_rel.type_id = $drone_run_band_drone_run_project_relationship_type_id_cvterm_id)
            JOIN project AS drone_run_project ON (drone_run_project.project_id = drone_run_band_rel.object_project_id)
            JOIN project_relationship ON (drone_run_project.project_id = project_relationship.subject_project_id AND project_relationship.type_id=$drone_run_field_trial_project_relationship_type_id_cvterm_id)
            LEFT JOIN projectprop ON (drone_run_band_project.project_id = projectprop.project_id AND projectprop.type_id=$drone_run_related_time_cvterms_json_cvterm_id)
            WHERE project_relationship.object_project_id IN ($field_trial_id_list_string) ;";
        my $h = $schema->storage->dbh()->prepare($drone_run_time_q);
        $h->execute();
        my $refresh_mat_views = 0;
        while( my ($drone_run_project_id, $field_trial_project_id, $related_time_terms_json) = $h->fetchrow_array()) {
            my $related_time_terms;
            if (!$related_time_terms_json) {
                $related_time_terms = SGN::Controller::AJAX::DroneImagery::DroneImagery::_perform_gdd_calculation_and_drone_run_time_saving($c, $schema, $field_trial_project_id, $drone_run_project_id, $c->config->{noaa_ncdc_access_token}, 50, 'average_daily_temp_sum');
                $refresh_mat_views = 1;
            }
            else {
                $related_time_terms = decode_json $related_time_terms_json;
            }
            if (!exists($related_time_terms->{gdd_average_temp})) {
                $related_time_terms = SGN::Controller::AJAX::DroneImagery::DroneImagery::_perform_gdd_calculation_and_drone_run_time_saving($c, $schema, $field_trial_project_id, $drone_run_project_id, $c->config->{noaa_ncdc_access_token}, 50, 'average_daily_temp_sum');
                $refresh_mat_views = 1;
            }
        }
        if ($refresh_mat_views) {
            my $bs = CXGN::BreederSearch->new( { dbh=>$c->dbc->dbh, dbname=>$c->config->{dbname}, } );
            my $refresh = $bs->refresh_matviews($c->config->{dbhost}, $c->config->{dbname}, $c->config->{dbuser}, $c->config->{dbpass}, 'fullview', 'concurrent', $c->config->{basepath});
            sleep(10);
        }
    };

    my ($permanent_environment_structure_tempfile_fh, $permanent_environment_structure_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($permanent_environment_structure_env_tempfile_fh, $permanent_environment_structure_env_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($permanent_environment_structure_env_tempfile2_fh, $permanent_environment_structure_env_tempfile2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($permanent_environment_structure_env_tempfile_mat_fh, $permanent_environment_structure_env_tempfile_mat) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_tempfile_fh, $stats_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_tempfile_2_fh, $stats_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    $stats_tempfile_2 .= '.dat';
    my ($stats_prep_tempfile_fh, $stats_prep_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_prep_factor_tempfile_fh, $stats_prep_factor_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($parameter_tempfile_fh, $parameter_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    $parameter_tempfile .= '.f90';
    my ($parameter_asreml_tempfile_fh, $parameter_asreml_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    $parameter_asreml_tempfile .= '.as';
    my ($coeff_genetic_tempfile_fh, $coeff_genetic_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    $coeff_genetic_tempfile .= '_genetic_coefficients.csv';
    my ($coeff_pe_tempfile_fh, $coeff_pe_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    $coeff_pe_tempfile .= '_permanent_environment_coefficients.csv';

    my $stats_out_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/drone_stats_XXXXX');
    my $stats_out_tempfile = $c->config->{basepath}."/".$stats_out_tempfile_string;

    my ($stats_prep2_tempfile_fh, $stats_prep2_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_out_htp_rel_tempfile_input_fh, $stats_out_htp_rel_tempfile_input) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_out_htp_rel_tempfile_fh, $stats_out_htp_rel_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);

    my $stats_out_htp_rel_tempfile_out_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/drone_stats_XXXXX');
    my $stats_out_htp_rel_tempfile_out = $c->config->{basepath}."/".$stats_out_htp_rel_tempfile_out_string;

    my ($stats_out_pe_pheno_rel_tempfile_fh, $stats_out_pe_pheno_rel_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_out_pe_pheno_rel_tempfile2_fh, $stats_out_pe_pheno_rel_tempfile2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);

    my ($stats_out_param_tempfile_fh, $stats_out_param_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_out_tempfile_row_fh, $stats_out_tempfile_row) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_out_tempfile_col_fh, $stats_out_tempfile_col) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_out_tempfile_2dspl_fh, $stats_out_tempfile_2dspl) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_out_tempfile_residual_fh, $stats_out_tempfile_residual) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_out_tempfile_genetic_fh, $stats_out_tempfile_genetic) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
    my ($stats_out_tempfile_permanent_environment_fh, $stats_out_tempfile_permanent_environment) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);

    my $time = DateTime->now();
    my $timestamp = $time->ymd()."_".$time->hms();

    my $csv = Text::CSV->new({ sep_char => "\t" });

    my @legendre_coeff_exec = (
        '1 * $b',
        '$time * $b',
        '(1/2*(3*$time**2 - 1)*$b)',
        '1/2*(5*$time**3 - 3*$time)*$b',
        '1/8*(35*$time**4 - 30*$time**2 + 3)*$b',
        '1/16*(63*$time**5 - 70*$time**2 + 15*$time)*$b',
        '1/16*(231*$time**6 - 315*$time**4 + 105*$time**2 - 5)*$b'
    );

    my $env_factor = 1;
    my $env_sim_exec = {
        "linear_gradient" => '($a_env*$row_number/$max_row + $b_env*$col_number/$max_col)*($env_effect_max_altered-$env_effect_min_altered)/($phenotype_max_altered-$phenotype_min_altered)*$env_factor',
        "random_1d_normal_gradient" => '( (1/(2*3.14159)) * exp(-1*(($row_number/$max_row)**2)/2) )*($env_effect_max_altered-$env_effect_min_altered)/($phenotype_max_altered-$phenotype_min_altered)*$env_factor',
        "random_2d_normal_gradient" => '( exp( (-1/(2*(1-$ro_env**2))) * ( ( (($row_number - $mean_row)/$max_row)**2)/($sig_row**2) + ( (($col_number - $mean_col)/$max_col)**2)/($sig_col**2) - ((2**$ro_env)*(($row_number - $mean_row)/$max_row)*(($col_number - $mean_col)/$max_col) )/($sig_row*$sig_col) ) ) / (2*3.14159*$sig_row*$sig_col*sqrt(1-$ro_env**2)) )*($env_effect_max_altered-$env_effect_min_altered)/($phenotype_max_altered-$phenotype_min_altered)*$env_factor',
        "random" => 'rand(1)*($env_effect_max_altered-$env_effect_min_altered)/($phenotype_max_altered-$phenotype_min_altered)*$env_factor'
    };

    my $a_env = rand(1);
    my $b_env = rand(1);
    my $ro_env = rand(1);
    my $row_ro_env = rand(1);
    my $env_variance_percent = 0.2;

    $statistics_select = 'airemlf90_grm_random_regression_dap_blups';

    my (%phenotype_data_original, @data_matrix_original, @data_matrix_phenotypes_original);
    my (%trait_name_encoder, %trait_name_encoder_rev, %stock_info, %unique_accessions, %seen_days_after_plantings, %seen_times, %trait_to_time_map, %obsunit_row_col, %stock_row_col, %stock_name_row_col, %stock_row_col_id, %seen_rows, %seen_cols, %seen_plots, %seen_plot_names, %plot_id_map, %trait_composing_info, @sorted_trait_names, @unique_accession_names, @unique_plot_names, %seen_trial_ids, %seen_trait_names, %unique_traits_ids, @phenotype_header, $header_string);
    my (@sorted_scaled_ln_times, %plot_id_factor_map_reverse, %plot_id_count_map_reverse, %accession_id_factor_map, %accession_id_factor_map_reverse, %time_count_map_reverse, @rep_time_factors, @ind_rep_factors, %plot_rep_time_factor_map, %seen_rep_times, %seen_ind_reps, @legs_header, %polynomial_map);
    my $time_min = 100000000;
    my $time_max = 0;
    my $min_row = 10000000000;
    my $max_row = 0;
    my $min_col = 10000000000;
    my $max_col = 0;
    my $phenotype_min_original = 1000000000;
    my $phenotype_max_original = -1000000000;

    my @plot_ids_ordered;
    my $F;
    my $q_time;
    my $h_time;

    eval {
        print STDERR "PREPARE ORIGINAL PHENOTYPE FILES\n";
        my $phenotypes_search = CXGN::Phenotypes::SearchFactory->instantiate(
            'MaterializedViewTable',
            {
                bcs_schema=>$schema,
                data_level=>'plot',
                trait_list=>$trait_id_list,
                trial_list=>$field_trial_id_list,
                include_timestamp=>0,
                exclude_phenotype_outlier=>0
            }
        );
        my ($data, $unique_traits) = $phenotypes_search->search();
        @sorted_trait_names = sort keys %$unique_traits;

        if (scalar(@$trait_id_list) < 2) {
            $c->stash->{rest} = { error => "Select more than 2 time points!"};
            return;
        }

        if (scalar(@$data) == 0) {
            $c->stash->{rest} = { error => "There are no phenotypes for the trials and traits you have selected!"};
            return;
        }

        $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
        $h_time = $schema->storage->dbh()->prepare($q_time);

        foreach my $obs_unit (@$data){
            my $germplasm_name = $obs_unit->{germplasm_uniquename};
            my $germplasm_stock_id = $obs_unit->{germplasm_stock_id};
            my $replicate_number = $obs_unit->{obsunit_rep} || '';
            my $block_number = $obs_unit->{obsunit_block} || '';
            my $obsunit_stock_id = $obs_unit->{observationunit_stock_id};
            my $obsunit_stock_uniquename = $obs_unit->{observationunit_uniquename};
            my $row_number = $obs_unit->{obsunit_row_number} || '';
            my $col_number = $obs_unit->{obsunit_col_number} || '';
            push @plot_ids_ordered, $obsunit_stock_id;

            if ($row_number < $min_row) {
                $min_row = $row_number;
            }
            elsif ($row_number >= $max_row) {
                $max_row = $row_number;
            }
            if ($col_number < $min_col) {
                $min_col = $col_number;
            }
            elsif ($col_number >= $max_col) {
                $max_col = $col_number;
            }

            $obsunit_row_col{$row_number}->{$col_number} = {
                stock_id => $obsunit_stock_id,
                stock_uniquename => $obsunit_stock_uniquename
            };
            $seen_rows{$row_number}++;
            $seen_cols{$col_number}++;
            $plot_id_map{$obsunit_stock_id} = $obsunit_stock_uniquename;
            $seen_plot_names{$obsunit_stock_uniquename}++;
            $seen_plots{$obsunit_stock_id} = $obsunit_stock_uniquename;
            $stock_row_col{$obsunit_stock_id} = {
                row_number => $row_number,
                col_number => $col_number,
                obsunit_stock_id => $obsunit_stock_id,
                obsunit_name => $obsunit_stock_uniquename,
                rep => $replicate_number,
                block => $block_number,
                germplasm_stock_id => $germplasm_stock_id,
                germplasm_name => $germplasm_name
            };
            $stock_name_row_col{$obsunit_stock_uniquename} = {
                row_number => $row_number,
                col_number => $col_number,
                obsunit_stock_id => $obsunit_stock_id,
                obsunit_name => $obsunit_stock_uniquename,
                rep => $replicate_number,
                block => $block_number,
                germplasm_stock_id => $germplasm_stock_id,
                germplasm_name => $germplasm_name
            };
            $stock_row_col_id{$row_number}->{$col_number} = $obsunit_stock_id;
            $unique_accessions{$germplasm_name}++;
            $stock_info{$germplasm_stock_id} = {
                uniquename => $germplasm_name
            };
            my $observations = $obs_unit->{observations};
            foreach (@$observations){
                if ($_->{associated_image_project_time_json}) {
                    my $related_time_terms_json = decode_json $_->{associated_image_project_time_json};
                    my $time;
                    my $time_term_string = '';
                    if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                        $time = $related_time_terms_json->{gdd_average_temp} + 0;

                        my $gdd_term_string = "GDD $time";
                        $h_time->execute($gdd_term_string, 'cxgn_time_ontology');
                        my ($gdd_cvterm_id) = $h_time->fetchrow_array();

                        if (!$gdd_cvterm_id) {
                            my $new_gdd_term = $schema->resultset("Cv::Cvterm")->create_with({
                               name => $gdd_term_string,
                               cv => 'cxgn_time_ontology'
                            });
                            $gdd_cvterm_id = $new_gdd_term->cvterm_id();
                        }
                        $time_term_string = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $gdd_cvterm_id, 'extended');
                    }
                    elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                        my $time_days_cvterm = $related_time_terms_json->{day};
                        $time_term_string = $time_days_cvterm;
                        my $time_days = (split '\|', $time_days_cvterm)[0];
                        $time = (split ' ', $time_days)[1] + 0;

                        $seen_days_after_plantings{$time}++;
                    }

                    my $value = $_->{value};
                    my $trait_name = $_->{trait_name};
                    $phenotype_data_original{$obsunit_stock_uniquename}->{$time} = $value;
                    $seen_times{$time} = $trait_name;
                    $seen_trait_names{$trait_name} = $time_term_string;
                    $trait_to_time_map{$trait_name} = $time;

                    if ($value < $phenotype_min_original) {
                        $phenotype_min_original = $value;
                    }
                    elsif ($value >= $phenotype_max_original) {
                        $phenotype_max_original = $value;
                    }
                }
            }
        }
        if (scalar(keys %seen_times) == 0) {
            $c->stash->{rest} = { error => "There are no phenotypes with associated days after planting time associated to the traits you have selected!"};
            return;
        }

        @sorted_trait_names = sort {$a <=> $b} keys %seen_times;
        # print STDERR Dumper \@sorted_trait_names;

        my $trait_name_encoded = 1;
        foreach my $trait_name (@sorted_trait_names) {
            if (!exists($trait_name_encoder{$trait_name})) {
                my $trait_name_e = 't'.$trait_name_encoded;
                $trait_name_encoder{$trait_name} = $trait_name_e;
                $trait_name_encoder_rev{$trait_name_e} = $trait_name;
                $trait_name_encoded++;
            }
        }

        foreach (@sorted_trait_names) {
            if ($_ < $time_min) {
                $time_min = $_;
            }
            if ($_ >= $time_max) {
                $time_max = $_;
            }
        }
        print STDERR Dumper [$time_min, $time_max];

        while ( my ($trait_name, $time_term) = each %seen_trait_names) {
            push @{$trait_composing_info{$trait_name}}, $time_term;
        }

        @unique_plot_names = sort keys %seen_plot_names;
        if ($legendre_order_number >= scalar(@sorted_trait_names)) {
            $legendre_order_number = scalar(@sorted_trait_names) - 1;
        }

        my @sorted_trait_names_scaled;
        my $leg_pos_counter = 0;
        foreach (@sorted_trait_names) {
            my $scaled_time = ($_ - $time_min)/($time_max - $time_min);
            push @sorted_trait_names_scaled, $scaled_time;
            if ($leg_pos_counter < $legendre_order_number+1) {
                push @sorted_scaled_ln_times, log($scaled_time+0.0001);
            }
            $leg_pos_counter++;
        }
        my $sorted_trait_names_scaled_string = join ',', @sorted_trait_names_scaled;

        my $cmd = 'R -e "library(sommer); library(orthopolynom);
        polynomials <- leg(c('.$sorted_trait_names_scaled_string.'), n='.$legendre_order_number.', intercept=TRUE);
        write.table(polynomials, file=\''.$stats_out_tempfile.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');"';
        my $status = system($cmd);

        open(my $fh, '<', $stats_out_tempfile)
            or die "Could not open file '$stats_out_tempfile' $!";

            print STDERR "Opened $stats_out_tempfile\n";
            my $header = <$fh>;
            my @header_cols;
            if ($csv->parse($header)) {
                @header_cols = $csv->fields();
            }

            my $p_counter = 0;
            while (my $row = <$fh>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                my $time = $sorted_trait_names[$p_counter];
                $polynomial_map{$time} = \@columns;
                $p_counter++;
            }
        close($fh);

        open(my $F_prep, ">", $stats_prep_tempfile) || die "Can't open file ".$stats_prep_tempfile;
            print $F_prep "accession_id,accession_id_factor,plot_id,plot_id_factor,replicate,time,replicate_time,ind_replicate\n";
            foreach my $p (@unique_plot_names) {
                my $replicate = $stock_name_row_col{$p}->{rep};
                my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
                my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};
                foreach my $t (@sorted_trait_names) {
                    print $F_prep "$germplasm_stock_id,,$obsunit_stock_id,,$replicate,$t,$replicate"."_"."$t,$germplasm_stock_id"."_"."$replicate\n";
                }
            }
        close($F_prep);

        my $cmd_factor = 'R -e "library(data.table);
        mat <- fread(\''.$stats_prep_tempfile.'\', header=TRUE, sep=\',\');
        mat\$replicate_time <- as.numeric(as.factor(mat\$replicate_time));
        mat\$ind_replicate <- as.numeric(as.factor(mat\$ind_replicate));
        mat\$accession_id_factor <- as.numeric(as.factor(mat\$accession_id));
        mat\$plot_id_factor <- as.numeric(as.factor(mat\$plot_id));
        write.table(mat, file=\''.$stats_prep_factor_tempfile.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');"';
        my $status_factor = system($cmd_factor);

        open(my $fh_factor, '<', $stats_prep_factor_tempfile)
            or die "Could not open file '$stats_prep_factor_tempfile' $!";

            print STDERR "Opened $stats_prep_factor_tempfile\n";
            $header = <$fh_factor>;
            if ($csv->parse($header)) {
                @header_cols = $csv->fields();
            }

            my $line_factor_count = 0;
            while (my $row = <$fh_factor>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                my $accession_id = $columns[0];
                my $accession_id_factor = $columns[1];
                my $plot_id = $columns[2];
                my $plot_id_factor = $columns[3];
                my $rep = $columns[4];
                my $time = $columns[5];
                my $rep_time = $columns[6];
                my $ind_rep = $columns[7];
                $stock_row_col{$plot_id}->{plot_id_factor} = $plot_id_factor;
                $stock_name_row_col{$plot_id_map{$plot_id}}->{plot_id_factor} = $plot_id_factor;
                $plot_rep_time_factor_map{$plot_id}->{$rep}->{$time} = $rep_time;
                $seen_rep_times{$rep_time}++;
                $seen_ind_reps{$plot_id_factor}++;
                $accession_id_factor_map{$accession_id} = $accession_id_factor;
                $accession_id_factor_map_reverse{$accession_id_factor} = $stock_info{$accession_id}->{uniquename};
                $plot_id_factor_map_reverse{$plot_id_factor} = $seen_plots{$plot_id};
                $plot_id_count_map_reverse{$line_factor_count} = $seen_plots{$plot_id};
                $time_count_map_reverse{$line_factor_count} = $time;
                $line_factor_count++;
            }
        close($fh_factor);
        @rep_time_factors = sort keys %seen_rep_times;
        @ind_rep_factors = sort keys %seen_ind_reps;

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @data_matrix_phenotypes_row;
            my $current_trait_index = 0;
            foreach my $t (@sorted_trait_names) {
                my @row = (
                    $accession_id_factor_map{$germplasm_stock_id},
                    $obsunit_stock_id,
                    $replicate,
                    $t,
                    $plot_rep_time_factor_map{$obsunit_stock_id}->{$replicate}->{$t},
                    $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
                );

                my $polys = $polynomial_map{$t};
                push @row, @$polys;

                if (defined($phenotype_data_original{$p}->{$t})) {
                    if ($use_area_under_curve) {
                        my $val = 0;
                        foreach my $counter (0..$current_trait_index) {
                            if ($counter == 0) {
                                $val = $val + $phenotype_data_original{$p}->{$sorted_trait_names[$counter]} + 0;
                            }
                            else {
                                my $t1 = $sorted_trait_names[$counter-1];
                                my $t2 = $sorted_trait_names[$counter];
                                my $p1 = $phenotype_data_original{$p}->{$t1} + 0;
                                my $p2 = $phenotype_data_original{$p}->{$t2} + 0;
                                my $neg = 1;
                                my $min_val = $p1;
                                if ($p2 < $p1) {
                                    $neg = -1;
                                    $min_val = $p2;
                                }
                                $val = $val + (($neg*($p2-$p1)*($t2-$t1))/2)+($t2-$t1)*$min_val;
                            }
                        }

                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                    else {
                        push @row, $phenotype_data_original{$p}->{$t} + 0;
                        push @data_matrix_phenotypes_row, $phenotype_data_original{$p}->{$t} + 0;
                    }
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                    push @data_matrix_phenotypes_row, 'NA';
                }

                push @data_matrix_original, \@row;
                push @data_matrix_phenotypes_original, \@data_matrix_phenotypes_row;

                $current_trait_index++;
            }
        }

        for (0..$legendre_order_number) {
            push @legs_header, "legendre$_";
        }
        @phenotype_header = ("id", "plot_id", "replicate", "time", "replicate_time", "ind_replicate", @legs_header, "phenotype");
        open($F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            foreach (@data_matrix_original) {
                my $line = join ' ', @$_;
                print $F "$line\n";
            }
        close($F);

        open(my $F2, ">", $stats_prep2_tempfile) || die "Can't open file ".$stats_prep2_tempfile;
            foreach (@data_matrix_phenotypes_original) {
                my $line = join ',', @$_;
                print $F2 "$line\n";
            }
        close($F2);

        if ($permanent_environment_structure eq 'euclidean_rows_and_columns') {
            my $data = '';
            my %euclidean_distance_hash;
            my $min_euc_dist = 10000000000000000000;
            my $max_euc_dist = 0;
            foreach my $s (sort { $a <=> $b } @plot_ids_ordered) {
                foreach my $r (sort { $a <=> $b } @plot_ids_ordered) {
                    my $s_factor = $stock_name_row_col{$plot_id_map{$s}}->{plot_id_factor};
                    my $r_factor = $stock_name_row_col{$plot_id_map{$r}}->{plot_id_factor};
                    if (!exists($euclidean_distance_hash{$s_factor}->{$r_factor}) && !exists($euclidean_distance_hash{$r_factor}->{$s_factor})) {
                        my $row_1 = $stock_name_row_col{$plot_id_map{$s}}->{row_number};
                        my $col_1 = $stock_name_row_col{$plot_id_map{$s}}->{col_number};
                        my $row_2 = $stock_name_row_col{$plot_id_map{$r}}->{row_number};
                        my $col_2 = $stock_name_row_col{$plot_id_map{$r}}->{col_number};
                        my $dist = sqrt( ($row_2 - $row_1)**2 + ($col_2 - $col_1)**2 );
                        if ($dist != 0) {
                            $dist = 1/$dist;
                        }
                        if (defined $dist and length $dist) {
                            $euclidean_distance_hash{$s_factor}->{$r_factor} = $dist;

                            if ($dist < $min_euc_dist) {
                                $min_euc_dist = $dist;
                            }
                            elsif ($dist > $max_euc_dist) {
                                $max_euc_dist = $dist;
                            }
                        }
                        else {
                            $c->stash->{rest} = { error => "There are not rows and columns for all of the plots! Do not try to use a Euclidean distance between plots for the permanent environment structure"};
                            return;
                        }
                    }
                }
            }

            foreach my $r (sort { $a <=> $b } keys %euclidean_distance_hash) {
                foreach my $s (sort { $a <=> $b } keys %{$euclidean_distance_hash{$r}}) {
                    my $val = $euclidean_distance_hash{$r}->{$s};
                    if (defined $val and length $val) {
                        my $val_scaled = ($val-$min_euc_dist)/($max_euc_dist-$min_euc_dist);
                        $data .= "$r\t$s\t$val_scaled\n";
                    }
                }
            }

            open(my $F3, ">", $permanent_environment_structure_tempfile) || die "Can't open file ".$permanent_environment_structure_tempfile;
                print $F3 $data;
            close($F3);
        }
        elsif ($permanent_environment_structure eq 'phenotype_correlation') {
            my $phenotypes_search_permanent_environment_structure = CXGN::Phenotypes::SearchFactory->instantiate(
                'MaterializedViewTable',
                {
                    bcs_schema=>$schema,
                    data_level=>'plot',
                    trial_list=>$field_trial_id_list,
                    trait_list=>$permanent_environment_structure_phenotype_correlation_traits,
                    include_timestamp=>0,
                    exclude_phenotype_outlier=>0
                }
            );
            my ($data_permanent_environment_structure, $unique_traits_permanent_environment_structure) = $phenotypes_search_permanent_environment_structure->search();

            if (scalar(@$data_permanent_environment_structure) == 0) {
                $c->stash->{rest} = { error => "There are no phenotypes for the permanent environment structure traits you have selected!"};
                return;
            }

            my %seen_plot_names_pe_rel;
            my %phenotype_data_pe_rel;
            my %seen_traits_pe_rel;
            foreach my $obs_unit (@$data_permanent_environment_structure){
                my $obsunit_stock_uniquename = $obs_unit->{observationunit_uniquename};
                my $germplasm_name = $obs_unit->{germplasm_uniquename};
                my $germplasm_stock_id = $obs_unit->{germplasm_stock_id};
                my $row_number = $obs_unit->{obsunit_row_number} || '';
                my $col_number = $obs_unit->{obsunit_col_number} || '';
                my $rep = $obs_unit->{obsunit_rep};
                my $block = $obs_unit->{obsunit_block};
                $seen_plot_names_pe_rel{$obsunit_stock_uniquename} = $obs_unit;
                my $observations = $obs_unit->{observations};
                foreach (@$observations){
                    $phenotype_data_pe_rel{$obsunit_stock_uniquename}->{$_->{trait_name}} = $_->{value};
                    $seen_traits_pe_rel{$_->{trait_name}}++;
                }
            }

            my @seen_plot_names_pe_rel_sorted = sort keys %seen_plot_names_pe_rel;
            my @seen_traits_pe_rel_sorted = sort keys %seen_traits_pe_rel;

            my @header_pe = ('plot_id');

            my %trait_name_encoder_pe;
            my %trait_name_encoder_rev_pe;
            my $trait_name_encoded_pe = 1;
            my @header_traits_pe;
            foreach my $trait_name (@seen_traits_pe_rel_sorted) {
                if (!exists($trait_name_encoder_pe{$trait_name})) {
                    my $trait_name_e = 't'.$trait_name_encoded_pe;
                    $trait_name_encoder_pe{$trait_name} = $trait_name_e;
                    $trait_name_encoder_rev_pe{$trait_name_e} = $trait_name;
                    push @header_traits_pe, $trait_name_e;
                    $trait_name_encoded_pe++;
                }
            }

            my @pe_pheno_matrix;
            push @header_pe, @header_traits_pe;
            push @pe_pheno_matrix, \@header_pe;

            foreach my $p (@seen_plot_names_pe_rel_sorted) {
                my @row = ($stock_name_row_col{$p}->{plot_id_factor});
                foreach my $t (@seen_traits_pe_rel_sorted) {
                    my $val = $phenotype_data_pe_rel{$p}->{$t} + 0;
                    push @row, $val;
                }
                push @pe_pheno_matrix, \@row;
            }

            open(my $pe_pheno_f, ">", $stats_out_pe_pheno_rel_tempfile) || die "Can't open file ".$stats_out_pe_pheno_rel_tempfile;
                foreach (@pe_pheno_matrix) {
                    my $line = join "\t", @$_;
                    print $pe_pheno_f $line."\n";
                }
            close($pe_pheno_f);

            my %rel_pe_result_hash;
            my $pe_rel_cmd = 'R -e "library(lme4); library(data.table);
            mat_agg <- fread(\''.$stats_out_pe_pheno_rel_tempfile.'\', header=TRUE, sep=\'\t\');
            mat_pheno <- mat_agg[,2:ncol(mat_agg)];
            cor_mat <- cor(t(mat_pheno));
            rownames(cor_mat) <- mat_agg\$plot_id;
            colnames(cor_mat) <- mat_agg\$plot_id;
            range01 <- function(x){(x-min(x))/(max(x)-min(x))};
            cor_mat <- range01(cor_mat);
            write.table(cor_mat, file=\''.$stats_out_pe_pheno_rel_tempfile2.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
            # print STDERR Dumper $pe_rel_cmd;
            my $status_pe_rel = system($pe_rel_cmd);

            my $csv = Text::CSV->new({ sep_char => "\t" });

            open(my $pe_rel_res, '<', $stats_out_pe_pheno_rel_tempfile2)
                or die "Could not open file '$stats_out_pe_pheno_rel_tempfile2' $!";

                print STDERR "Opened $stats_out_pe_pheno_rel_tempfile2\n";
                my $header_row = <$pe_rel_res>;
                my @header;
                if ($csv->parse($header_row)) {
                    @header = $csv->fields();
                }

                while (my $row = <$pe_rel_res>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }
                    my $stock_id1 = $columns[0];
                    my $counter = 1;
                    foreach my $stock_id2 (@header) {
                        my $val = $columns[$counter];
                        $rel_pe_result_hash{$stock_id1}->{$stock_id2} = $val;
                        $counter++;
                    }
                }
            close($pe_rel_res);

            my $data_rel_pe = '';
            my %result_hash_pe;
            foreach my $s (sort { $a <=> $b } @plot_ids_ordered) {
                foreach my $r (sort { $a <=> $b } @plot_ids_ordered) {
                    my $s_factor = $stock_name_row_col{$plot_id_map{$s}}->{plot_id_factor};
                    my $r_factor = $stock_name_row_col{$plot_id_map{$r}}->{plot_id_factor};
                    if (!exists($result_hash_pe{$s_factor}->{$r_factor}) && !exists($result_hash_pe{$r_factor}->{$s_factor})) {
                        $result_hash_pe{$s_factor}->{$r_factor} = $rel_pe_result_hash{$s_factor}->{$r_factor};
                    }
                }
            }
            foreach my $r (sort { $a <=> $b } keys %result_hash_pe) {
                foreach my $s (sort { $a <=> $b } keys %{$result_hash_pe{$r}}) {
                    my $val = $result_hash_pe{$r}->{$s};
                    if (defined $val and length $val) {
                        $data_rel_pe .= "$r\t$s\t$val\n";
                    }
                }
            }

            open(my $pe_rel_out, ">", $permanent_environment_structure_tempfile) || die "Can't open file ".$permanent_environment_structure_tempfile;
                print $pe_rel_out $data_rel_pe;
            close($pe_rel_out);
        }

        print STDERR Dumper [$phenotype_min_original, $phenotype_max_original];

        @unique_accession_names = sort keys %unique_accessions;
        @unique_plot_names = sort keys %seen_plot_names;
    };

    my @seen_rows_array = keys %seen_rows;
    my @seen_cols_array = keys %seen_cols;
    my $row_stat = Statistics::Descriptive::Full->new();
    $row_stat->add_data(@seen_rows_array);
    my $mean_row = $row_stat->mean();
    my $sig_row = $row_stat->variance();
    my $col_stat = Statistics::Descriptive::Full->new();
    $col_stat->add_data(@seen_cols_array);
    my $mean_col = $col_stat->mean();
    my $sig_col = $col_stat->variance();

    print STDERR "PREPARE RELATIONSHIP MATRIX\n";
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_temporal_random_regression_dap_genetic_blups' || $statistics_select eq 'sommer_grm_temporal_random_regression_gdd_genetic_blups' || $statistics_select eq 'sommer_grm_genetic_only_random_regression_dap_genetic_blups'
        || $statistics_select eq 'sommer_grm_genetic_only_random_regression_gdd_genetic_blups' || $statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups'
        || $statistics_select eq 'sommer_grm_genetic_blups') {

        my %seen_accession_stock_ids;
        foreach my $trial_id (@$field_trial_id_list) {
            my $trial = CXGN::Trial->new({ bcs_schema => $schema, trial_id => $trial_id });
            my $accessions = $trial->get_accessions();
            foreach (@$accessions) {
                $seen_accession_stock_ids{$_->{stock_id}}++;
            }
        }
        my @accession_ids = keys %seen_accession_stock_ids;

        if ($compute_relationship_matrix_from_htp_phenotypes eq 'genotypes') {

            if ($include_pedgiree_info_if_compute_from_parents) {
                my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
                my $tmp_arm_dir = $shared_cluster_dir_config."/tmp_download_arm";
                mkdir $tmp_arm_dir if ! -d $tmp_arm_dir;
                my ($arm_tempfile_fh, $arm_tempfile) = tempfile("drone_stats_download_arm_XXXXX", DIR=> $tmp_arm_dir);
                my ($grm1_tempfile_fh, $grm1_tempfile) = tempfile("drone_stats_download_grm1_XXXXX", DIR=> $tmp_arm_dir);
                my ($grm_out_temp_tempfile_fh, $grm_out_temp_tempfile) = tempfile("drone_stats_download_grm_temp_out_XXXXX", DIR=> $tmp_arm_dir);
                my ($grm_out_tempfile_fh, $grm_out_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);
                my ($grm_out_posdef_tempfile_fh, $grm_out_posdef_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);

                if (!$protocol_id) {
                    $protocol_id = undef;
                }

                my $pedigree_arm = CXGN::Pedigree::ARM->new({
                    bcs_schema=>$schema,
                    arm_temp_file=>$arm_tempfile,
                    people_schema=>$people_schema,
                    accession_id_list=>\@accession_ids,
                    # plot_id_list=>\@plot_id_list,
                    cache_root=>$c->config->{cache_file_path},
                    download_format=>'matrix', #either 'matrix', 'three_column', or 'heatmap'
                });
                my ($parent_hash, $stock_ids, $all_accession_stock_ids, $female_stock_ids, $male_stock_ids) = $pedigree_arm->get_arm(
                    $shared_cluster_dir_config,
                    $c->config->{backend},
                    $c->config->{cluster_host},
                    $c->config->{'web_cluster_queue'},
                    $c->config->{basepath}
                );
                # print STDERR Dumper $parent_hash;

                my $female_geno = CXGN::Genotype::GRM->new({
                    bcs_schema=>$schema,
                    grm_temp_file=>$grm1_tempfile,
                    people_schema=>$people_schema,
                    cache_root=>$c->config->{cache_file_path},
                    accession_id_list=>$female_stock_ids,
                    protocol_id=>$protocol_id,
                    get_grm_for_parental_accessions=>0,
                    download_format=>'three_column_reciprocal'
                    # minor_allele_frequency=>$minor_allele_frequency,
                    # marker_filter=>$marker_filter,
                    # individuals_filter=>$individuals_filter
                });
                my $female_grm_data = $female_geno->download_grm(
                    'data',
                    $shared_cluster_dir_config,
                    $c->config->{backend},
                    $c->config->{cluster_host},
                    $c->config->{'web_cluster_queue'},
                    $c->config->{basepath}
                );
                my @fl = split '\n', $female_grm_data;
                my %female_parent_grm;
                foreach (@fl) {
                    my @l = split '\t', $_;
                    $female_parent_grm{$l[0]}->{$l[1]} = $l[2];
                }
                # print STDERR Dumper \%female_parent_grm;

                my $male_geno = CXGN::Genotype::GRM->new({
                    bcs_schema=>$schema,
                    grm_temp_file=>$grm1_tempfile,
                    people_schema=>$people_schema,
                    cache_root=>$c->config->{cache_file_path},
                    accession_id_list=>$male_stock_ids,
                    protocol_id=>$protocol_id,
                    get_grm_for_parental_accessions=>0,
                    download_format=>'three_column_reciprocal'
                    # minor_allele_frequency=>$minor_allele_frequency,
                    # marker_filter=>$marker_filter,
                    # individuals_filter=>$individuals_filter
                });
                my $male_grm_data = $male_geno->download_grm(
                    'data',
                    $shared_cluster_dir_config,
                    $c->config->{backend},
                    $c->config->{cluster_host},
                    $c->config->{'web_cluster_queue'},
                    $c->config->{basepath}
                );
                my @ml = split '\n', $male_grm_data;
                my %male_parent_grm;
                foreach (@ml) {
                    my @l = split '\t', $_;
                    $male_parent_grm{$l[0]}->{$l[1]} = $l[2];
                }
                # print STDERR Dumper \%male_parent_grm;

                my %rel_result_hash;
                foreach my $a1 (@accession_ids) {
                    foreach my $a2 (@accession_ids) {
                        my $female_parent1 = $parent_hash->{$a1}->{female_stock_id};
                        my $male_parent1 = $parent_hash->{$a1}->{male_stock_id};
                        my $female_parent2 = $parent_hash->{$a2}->{female_stock_id};
                        my $male_parent2 = $parent_hash->{$a2}->{male_stock_id};

                        my $female_rel = 0;
                        if ($female_parent1 && $female_parent2 && $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2}) {
                            $female_rel = $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2};
                        }
                        elsif ($female_parent1 && $female_parent2 && $female_parent1 == $female_parent2) {
                            $female_rel = 1;
                        }
                        elsif ($a1 == $a2) {
                            $female_rel = 1;
                        }

                        my $male_rel = 0;
                        if ($male_parent1 && $male_parent2 && $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2}) {
                            $male_rel = $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2};
                        }
                        elsif ($male_parent1 && $male_parent2 && $male_parent1 == $male_parent2) {
                            $male_rel = 1;
                        }
                        elsif ($a1 == $a2) {
                            $male_rel = 1;
                        }
                        # print STDERR "$a1 $a2 $female_rel $male_rel\n";

                        my $rel = 0.5*($female_rel + $male_rel);
                        $rel_result_hash{$a1}->{$a2} = $rel;
                    }
                }
                # print STDERR Dumper \%rel_result_hash;

                my $data = '';
                my %result_hash;
                foreach my $s (sort @accession_ids) {
                    foreach my $c (sort @accession_ids) {
                        if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                            my $val = $rel_result_hash{$s}->{$c};
                            if (defined $val and length $val) {
                                $result_hash{$s}->{$c} = $val;
                                $data .= "S$s\tS$c\t$val\n";
                            }
                        }
                    }
                }

                # print STDERR Dumper $data;
                open(my $F2, ">", $grm_out_temp_tempfile) || die "Can't open file ".$grm_out_temp_tempfile;
                    print $F2 $data;
                close($F2);

                my $cmd = 'R -e "library(data.table); library(scales); library(tidyr); library(reshape2);
                three_col <- fread(\''.$grm_out_temp_tempfile.'\', header=FALSE, sep=\'\t\');
                A_wide <- dcast(three_col, V1~V2, value.var=\'V3\');
                A_1 <- A_wide[,-1];
                A_1[is.na(A_1)] <- 0;
                A <- A_1 + t(A_1);
                diag(A) <- diag(as.matrix(A_1));
                E = eigen(A);
                ev = E\$values;
                U = E\$vectors;
                no = dim(A)[1];
                nev = which(ev < 0);
                wr = 0;
                k=length(nev);
                if(k > 0){
                    p = ev[no - k];
                    B = sum(ev[nev])*2.0;
                    wr = (B*B*100.0)+1;
                    val = ev[nev];
                    ev[nev] = p*(B-val)*(B-val)/wr;
                    A = U%*%diag(ev)%*%t(U);
                }
                A <- as.data.frame(A);
                colnames(A) <- A_wide[,1];
                A\$stock_id <- A_wide[,1];
                A_threecol <- melt(A, id.vars = c(\'stock_id\'), measure.vars = A_wide[,1]);
                A_threecol\$stock_id <- substring(A_threecol\$stock_id, 2);
                A_threecol\$variable <- substring(A_threecol\$variable, 2);
                write.table(data.frame(variable = A_threecol\$variable, stock_id = A_threecol\$stock_id, value = A_threecol\$value), file=\''.$grm_out_tempfile.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');"';
                print STDERR $cmd."\n";
                my $status = system($cmd);

                my %rel_pos_def_result_hash;
                open(my $F3, '<', $grm_out_tempfile)
                    or die "Could not open file '$grm_out_tempfile' $!";

                    print STDERR "Opened $grm_out_tempfile\n";

                    while (my $row = <$F3>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $stock_id1 = $columns[0];
                        my $stock_id2 = $columns[1];
                        my $val = $columns[2];
                        $rel_pos_def_result_hash{$stock_id1}->{$stock_id2} = $val;
                    }
                close($F3);

                my $data_pos_def = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    my %result_hash;
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_pos_def_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $data_pos_def .= "$s\t$c\t$val\n";
                                }
                            }
                        }
                    }
                }
                else {
                    my %result_hash;
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_pos_def_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $result_hash{$c}->{$s} = $val;
                                    $data_pos_def .= "S$s\tS$c\t$val\n";
                                    if ($s != $c) {
                                        $data_pos_def .= "S$c\tS$s\t$val\n";
                                    }
                                }
                            }
                        }
                    }
                }

                open(my $F4, ">", $grm_out_posdef_tempfile) || die "Can't open file ".$grm_out_posdef_tempfile;
                    print $F4 $data_pos_def;
                close($F4);

                $grm_file = $grm_out_posdef_tempfile;
            }
            elsif ($use_parental_grms_if_compute_from_parents) {
                my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
                my $tmp_arm_dir = $shared_cluster_dir_config."/tmp_download_arm";
                mkdir $tmp_arm_dir if ! -d $tmp_arm_dir;
                my ($arm_tempfile_fh, $arm_tempfile) = tempfile("drone_stats_download_arm_XXXXX", DIR=> $tmp_arm_dir);
                my ($grm1_tempfile_fh, $grm1_tempfile) = tempfile("drone_stats_download_grm1_XXXXX", DIR=> $tmp_arm_dir);
                my ($grm_out_temp_tempfile_fh, $grm_out_temp_tempfile) = tempfile("drone_stats_download_grm_temp_out_XXXXX", DIR=> $tmp_arm_dir);
                my ($grm_out_tempfile_fh, $grm_out_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);
                my ($grm_out_posdef_tempfile_fh, $grm_out_posdef_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);

                if (!$protocol_id) {
                    $protocol_id = undef;
                }

                my $pedigree_arm = CXGN::Pedigree::ARM->new({
                    bcs_schema=>$schema,
                    arm_temp_file=>$arm_tempfile,
                    people_schema=>$people_schema,
                    accession_id_list=>\@accession_ids,
                    # plot_id_list=>\@plot_id_list,
                    cache_root=>$c->config->{cache_file_path},
                    download_format=>'matrix', #either 'matrix', 'three_column', or 'heatmap'
                });
                my ($parent_hash, $stock_ids, $all_accession_stock_ids, $female_stock_ids, $male_stock_ids) = $pedigree_arm->get_arm(
                    $shared_cluster_dir_config,
                    $c->config->{backend},
                    $c->config->{cluster_host},
                    $c->config->{'web_cluster_queue'},
                    $c->config->{basepath}
                );
                # print STDERR Dumper $parent_hash;

                my $female_geno = CXGN::Genotype::GRM->new({
                    bcs_schema=>$schema,
                    grm_temp_file=>$grm1_tempfile,
                    people_schema=>$people_schema,
                    cache_root=>$c->config->{cache_file_path},
                    accession_id_list=>$female_stock_ids,
                    protocol_id=>$protocol_id,
                    get_grm_for_parental_accessions=>0,
                    download_format=>'three_column_reciprocal'
                    # minor_allele_frequency=>$minor_allele_frequency,
                    # marker_filter=>$marker_filter,
                    # individuals_filter=>$individuals_filter
                });
                my $female_grm_data = $female_geno->download_grm(
                    'data',
                    $shared_cluster_dir_config,
                    $c->config->{backend},
                    $c->config->{cluster_host},
                    $c->config->{'web_cluster_queue'},
                    $c->config->{basepath}
                );
                my @fl = split '\n', $female_grm_data;
                my %female_parent_grm;
                foreach (@fl) {
                    my @l = split '\t', $_;
                    $female_parent_grm{$l[0]}->{$l[1]} = $l[2];
                }
                # print STDERR Dumper \%female_parent_grm;

                my $male_geno = CXGN::Genotype::GRM->new({
                    bcs_schema=>$schema,
                    grm_temp_file=>$grm1_tempfile,
                    people_schema=>$people_schema,
                    cache_root=>$c->config->{cache_file_path},
                    accession_id_list=>$male_stock_ids,
                    protocol_id=>$protocol_id,
                    get_grm_for_parental_accessions=>0,
                    download_format=>'three_column_reciprocal'
                    # minor_allele_frequency=>$minor_allele_frequency,
                    # marker_filter=>$marker_filter,
                    # individuals_filter=>$individuals_filter
                });
                my $male_grm_data = $male_geno->download_grm(
                    'data',
                    $shared_cluster_dir_config,
                    $c->config->{backend},
                    $c->config->{cluster_host},
                    $c->config->{'web_cluster_queue'},
                    $c->config->{basepath}
                );
                my @ml = split '\n', $male_grm_data;
                my %male_parent_grm;
                foreach (@ml) {
                    my @l = split '\t', $_;
                    $male_parent_grm{$l[0]}->{$l[1]} = $l[2];
                }
                # print STDERR Dumper \%male_parent_grm;

                my %rel_result_hash;
                foreach my $a1 (@accession_ids) {
                    foreach my $a2 (@accession_ids) {
                        my $female_parent1 = $parent_hash->{$a1}->{female_stock_id};
                        my $male_parent1 = $parent_hash->{$a1}->{male_stock_id};
                        my $female_parent2 = $parent_hash->{$a2}->{female_stock_id};
                        my $male_parent2 = $parent_hash->{$a2}->{male_stock_id};

                        my $female_rel = 0;
                        if ($female_parent1 && $female_parent2 && $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2}) {
                            $female_rel = $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2};
                        }
                        elsif ($a1 == $a2) {
                            $female_rel = 1;
                        }

                        my $male_rel = 0;
                        if ($male_parent1 && $male_parent2 && $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2}) {
                            $male_rel = $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2};
                        }
                        elsif ($a1 == $a2) {
                            $male_rel = 1;
                        }
                        # print STDERR "$a1 $a2 $female_rel $male_rel\n";

                        my $rel = 0.5*($female_rel + $male_rel);
                        $rel_result_hash{$a1}->{$a2} = $rel;
                    }
                }
                # print STDERR Dumper \%rel_result_hash;

                my $data = '';
                my %result_hash;
                foreach my $s (sort @accession_ids) {
                    foreach my $c (sort @accession_ids) {
                        if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                            my $val = $rel_result_hash{$s}->{$c};
                            if (defined $val and length $val) {
                                $result_hash{$s}->{$c} = $val;
                                $data .= "S$s\tS$c\t$val\n";
                            }
                        }
                    }
                }

                # print STDERR Dumper $data;
                open(my $F2, ">", $grm_out_temp_tempfile) || die "Can't open file ".$grm_out_temp_tempfile;
                    print $F2 $data;
                close($F2);

                my $cmd = 'R -e "library(data.table); library(scales); library(tidyr); library(reshape2);
                three_col <- fread(\''.$grm_out_temp_tempfile.'\', header=FALSE, sep=\'\t\');
                A_wide <- dcast(three_col, V1~V2, value.var=\'V3\');
                A_1 <- A_wide[,-1];
                A_1[is.na(A_1)] <- 0;
                A <- A_1 + t(A_1);
                diag(A) <- diag(as.matrix(A_1));
                E = eigen(A);
                ev = E\$values;
                U = E\$vectors;
                no = dim(A)[1];
                nev = which(ev < 0);
                wr = 0;
                k=length(nev);
                if(k > 0){
                    p = ev[no - k];
                    B = sum(ev[nev])*2.0;
                    wr = (B*B*100.0)+1;
                    val = ev[nev];
                    ev[nev] = p*(B-val)*(B-val)/wr;
                    A = U%*%diag(ev)%*%t(U);
                }
                A <- as.data.frame(A);
                colnames(A) <- A_wide[,1];
                A\$stock_id <- A_wide[,1];
                A_threecol <- melt(A, id.vars = c(\'stock_id\'), measure.vars = A_wide[,1]);
                A_threecol\$stock_id <- substring(A_threecol\$stock_id, 2);
                A_threecol\$variable <- substring(A_threecol\$variable, 2);
                write.table(data.frame(variable = A_threecol\$variable, stock_id = A_threecol\$stock_id, value = A_threecol\$value), file=\''.$grm_out_tempfile.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');"';
                print STDERR $cmd."\n";
                my $status = system($cmd);

                my %rel_pos_def_result_hash;
                open(my $F3, '<', $grm_out_tempfile)
                    or die "Could not open file '$grm_out_tempfile' $!";

                    print STDERR "Opened $grm_out_tempfile\n";

                    while (my $row = <$F3>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $stock_id1 = $columns[0];
                        my $stock_id2 = $columns[1];
                        my $val = $columns[2];
                        $rel_pos_def_result_hash{$stock_id1}->{$stock_id2} = $val;
                    }
                close($F3);

                my $data_pos_def = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    my %result_hash;
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_pos_def_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $data_pos_def .= "$s\t$c\t$val\n";
                                }
                            }
                        }
                    }
                }
                else {
                    my %result_hash;
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_pos_def_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $result_hash{$c}->{$s} = $val;
                                    $data_pos_def .= "S$s\tS$c\t$val\n";
                                    if ($s != $c) {
                                        $data_pos_def .= "S$c\tS$s\t$val\n";
                                    }
                                }
                            }
                        }
                    }
                }

                open(my $F4, ">", $grm_out_posdef_tempfile) || die "Can't open file ".$grm_out_posdef_tempfile;
                    print $F4 $data_pos_def;
                close($F4);

                $grm_file = $grm_out_posdef_tempfile;
            }
            else {
                my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
                my $tmp_grm_dir = $shared_cluster_dir_config."/tmp_genotype_download_grm";
                mkdir $tmp_grm_dir if ! -d $tmp_grm_dir;
                my ($grm_tempfile_fh, $grm_tempfile) = tempfile("drone_stats_download_grm_XXXXX", DIR=> $tmp_grm_dir);
                my ($grm_out_tempfile_fh, $grm_out_tempfile) = tempfile("drone_stats_download_grm_XXXXX", DIR=> $tmp_grm_dir);

                if (!$protocol_id) {
                    $protocol_id = undef;
                }

                my $grm_search_params = {
                    bcs_schema=>$schema,
                    grm_temp_file=>$grm_tempfile,
                    people_schema=>$people_schema,
                    cache_root=>$c->config->{cache_file_path},
                    accession_id_list=>\@accession_ids,
                    protocol_id=>$protocol_id,
                    get_grm_for_parental_accessions=>$compute_from_parents,
                    # minor_allele_frequency=>$minor_allele_frequency,
                    # marker_filter=>$marker_filter,
                    # individuals_filter=>$individuals_filter
                };

                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $grm_search_params->{download_format} = 'three_column_stock_id_integer';
                }
                else {
                    $grm_search_params->{download_format} = 'three_column_reciprocal';
                }

                my $geno = CXGN::Genotype::GRM->new($grm_search_params);
                my $grm_data = $geno->download_grm(
                    'data',
                    $shared_cluster_dir_config,
                    $c->config->{backend},
                    $c->config->{cluster_host},
                    $c->config->{'web_cluster_queue'},
                    $c->config->{basepath}
                );

                open(my $F2, ">", $grm_out_tempfile) || die "Can't open file ".$grm_out_tempfile;
                    print $F2 $grm_data;
                close($F2);
                $grm_file = $grm_out_tempfile;
            }

        }
        elsif ($compute_relationship_matrix_from_htp_phenotypes eq 'htp_phenotypes') {

            my $phenotypes_search = CXGN::Phenotypes::SearchFactory->instantiate(
                'MaterializedViewTable',
                {
                    bcs_schema=>$schema,
                    data_level=>'plot',
                    trial_list=>$field_trial_id_list,
                    include_timestamp=>0,
                    exclude_phenotype_outlier=>0
                }
            );
            my ($data, $unique_traits) = $phenotypes_search->search();

            if (scalar(@$data) == 0) {
                $c->stash->{rest} = { error => "There are no phenotypes for the trial you have selected!"};
                return;
            }

            my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
            my $h_time = $schema->storage->dbh()->prepare($q_time);

            my %seen_plot_names_htp_rel;
            my %phenotype_data_htp_rel;
            my %seen_times_htp_rel;
            foreach my $obs_unit (@$data){
                my $germplasm_name = $obs_unit->{germplasm_uniquename};
                my $germplasm_stock_id = $obs_unit->{germplasm_stock_id};
                my $row_number = $obs_unit->{obsunit_row_number} || '';
                my $col_number = $obs_unit->{obsunit_col_number} || '';
                my $rep = $obs_unit->{obsunit_rep};
                my $block = $obs_unit->{obsunit_block};
                $seen_plot_names_htp_rel{$obs_unit->{observationunit_uniquename}} = $obs_unit;
                my $observations = $obs_unit->{observations};
                foreach (@$observations){
                    if ($_->{associated_image_project_time_json}) {
                        my $related_time_terms_json = decode_json $_->{associated_image_project_time_json};

                        my $time_days_cvterm = $related_time_terms_json->{day};
                        my $time_days_term_string = $time_days_cvterm;
                        my $time_days = (split '\|', $time_days_cvterm)[0];
                        my $time_days_value = (split ' ', $time_days)[1];

                        my $time_gdd_value = $related_time_terms_json->{gdd_average_temp} + 0;
                        my $gdd_term_string = "GDD $time_gdd_value";
                        $h_time->execute($gdd_term_string, 'cxgn_time_ontology');
                        my ($gdd_cvterm_id) = $h_time->fetchrow_array();
                        if (!$gdd_cvterm_id) {
                            my $new_gdd_term = $schema->resultset("Cv::Cvterm")->create_with({
                               name => $gdd_term_string,
                               cv => 'cxgn_time_ontology'
                            });
                            $gdd_cvterm_id = $new_gdd_term->cvterm_id();
                        }
                        my $time_gdd_term_string = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $gdd_cvterm_id, 'extended');

                        $phenotype_data_htp_rel{$obs_unit->{observationunit_uniquename}}->{$_->{trait_name}} = $_->{value};
                        $seen_times_htp_rel{$_->{trait_name}} = [$time_days_value, $time_days_term_string, $time_gdd_value, $time_gdd_term_string];
                    }
                }
            }

            my @allowed_standard_htp_values = ('Nonzero Pixel Count', 'Total Pixel Sum', 'Mean Pixel Value', 'Harmonic Mean Pixel Value', 'Median Pixel Value', 'Pixel Variance', 'Pixel Standard Deviation', 'Pixel Population Standard Deviation', 'Minimum Pixel Value', 'Maximum Pixel Value', 'Minority Pixel Value', 'Minority Pixel Count', 'Majority Pixel Value', 'Majority Pixel Count', 'Pixel Group Count');
            my %filtered_seen_times_htp_rel;
            while (my ($t, $time) = each %seen_times_htp_rel) {
                my $allowed = 0;
                foreach (@allowed_standard_htp_values) {
                    if (index($t, $_) != -1) {
                        $allowed = 1;
                        last;
                    }
                }
                if ($allowed) {
                    $filtered_seen_times_htp_rel{$t} = $time;
                }
            }

            my @seen_plot_names_htp_rel_sorted = sort keys %seen_plot_names_htp_rel;
            my @filtered_seen_times_htp_rel_sorted = sort keys %filtered_seen_times_htp_rel;

            my @header_htp = ('plot_id', 'plot_name', 'accession_id', 'accession_name', 'rep', 'block');

            my %trait_name_encoder_htp;
            my %trait_name_encoder_rev_htp;
            my $trait_name_encoded_htp = 1;
            my @header_traits_htp;
            foreach my $trait_name (@filtered_seen_times_htp_rel_sorted) {
                if (!exists($trait_name_encoder_htp{$trait_name})) {
                    my $trait_name_e = 't'.$trait_name_encoded_htp;
                    $trait_name_encoder_htp{$trait_name} = $trait_name_e;
                    $trait_name_encoder_rev_htp{$trait_name_e} = $trait_name;
                    push @header_traits_htp, $trait_name_e;
                    $trait_name_encoded_htp++;
                }
            }

            my @htp_pheno_matrix;
            if ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'all') {
                push @header_htp, @header_traits_htp;
                push @htp_pheno_matrix, \@header_htp;

                foreach my $p (@seen_plot_names_htp_rel_sorted) {
                    my $obj = $seen_plot_names_htp_rel{$p};
                    my @row = ($obj->{observationunit_stock_id}, $obj->{observationunit_uniquename}, $obj->{germplasm_stock_id}, $obj->{germplasm_uniquename}, $obj->{obsunit_rep}, $obj->{obsunit_block});
                    foreach my $t (@filtered_seen_times_htp_rel_sorted) {
                        my $val = $phenotype_data_htp_rel{$p}->{$t} + 0;
                        push @row, $val;
                    }
                    push @htp_pheno_matrix, \@row;
                }
            }
            elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'latest_trait') {
                my $max_day = 0;
                foreach (keys %seen_days_after_plantings) {
                    if ($_ + 0 > $max_day) {
                        $max_day = $_;
                    }
                }

                foreach my $t (@filtered_seen_times_htp_rel_sorted) {
                    my $day = $filtered_seen_times_htp_rel{$t}->[0];
                    if ($day <= $max_day) {
                        push @header_htp, $t;
                    }
                }
                push @htp_pheno_matrix, \@header_htp;

                foreach my $p (@seen_plot_names_htp_rel_sorted) {
                    my $obj = $seen_plot_names_htp_rel{$p};
                    my @row = ($obj->{observationunit_stock_id}, $obj->{observationunit_uniquename}, $obj->{germplasm_stock_id}, $obj->{germplasm_uniquename}, $obj->{obsunit_rep}, $obj->{obsunit_block});
                    foreach my $t (@filtered_seen_times_htp_rel_sorted) {
                        my $day = $filtered_seen_times_htp_rel{$t}->[0];
                        if ($day <= $max_day) {
                            my $val = $phenotype_data_htp_rel{$p}->{$t} + 0;
                            push @row, $val;
                        }
                    }
                    push @htp_pheno_matrix, \@row;
                }
            }
            elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'vegetative') {
                
            }
            elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'reproductive') {
                
            }
            elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'mature') {
                
            }
            else {
                $c->stash->{rest} = { error => "The value of $compute_relationship_matrix_from_htp_phenotypes_time_points htp_pheno_rel_matrix_time_points is not valid!" };
                return;
            }

            open(my $htp_pheno_f, ">", $stats_out_htp_rel_tempfile_input) || die "Can't open file ".$stats_out_htp_rel_tempfile_input;
                foreach (@htp_pheno_matrix) {
                    my $line = join "\t", @$_;
                    print $htp_pheno_f $line."\n";
                }
            close($htp_pheno_f);

            my %rel_htp_result_hash;
            if ($compute_relationship_matrix_from_htp_phenotypes_type eq 'correlations') {
                my $htp_cmd = 'R -e "library(lme4); library(data.table);
                mat <- fread(\''.$stats_out_htp_rel_tempfile_input.'\', header=TRUE, sep=\'\t\');
                mat_agg <- aggregate(mat[, 7:ncol(mat)], list(mat\$accession_id), mean);
                mat_pheno <- mat_agg[,2:ncol(mat_agg)];
                cor_mat <- cor(t(mat_pheno));
                rownames(cor_mat) <- mat_agg[,1];
                colnames(cor_mat) <- mat_agg[,1];
                range01 <- function(x){(x-min(x))/(max(x)-min(x))};
                cor_mat <- range01(cor_mat);
                write.table(cor_mat, file=\''.$stats_out_htp_rel_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
                print STDERR Dumper $htp_cmd;
                my $status = system($htp_cmd);
            }
            elsif ($compute_relationship_matrix_from_htp_phenotypes_type eq 'blues') {
                my $htp_cmd = 'R -e "library(lme4); library(data.table);
                mat <- fread(\''.$stats_out_htp_rel_tempfile_input.'\', header=TRUE, sep=\'\t\');
                blues <- data.frame(id = seq(1,length(unique(mat\$accession_id))));
                varlist <- names(mat)[7:ncol(mat)];
                blues.models <- lapply(varlist, function(x) {
                    tryCatch(
                        lmer(substitute(i ~ 1 + (1|accession_id), list(i = as.name(x))), data = mat, REML = FALSE, control = lmerControl(optimizer =\'Nelder_Mead\', boundary.tol='.$compute_relationship_matrix_from_htp_phenotypes_blues_inversion.' ) ), error=function(e) {}
                    )
                });
                counter = 1;
                for (m in blues.models) {
                    if (!is.null(m)) {
                        blues\$accession_id <- row.names(ranef(m)\$accession_id);
                        blues[,ncol(blues) + 1] <- ranef(m)\$accession_id\$\`(Intercept)\`;
                        colnames(blues)[ncol(blues)] <- varlist[counter];
                    }
                    counter = counter + 1;
                }
                blues_vals <- as.matrix(blues[,3:ncol(blues)]);
                blues_vals <- apply(blues_vals, 2, function(y) (y - mean(y)) / sd(y) ^ as.logical(sd(y)));
                rel <- (1/ncol(blues_vals)) * (blues_vals %*% t(blues_vals));
                rownames(rel) <- blues[,2];
                colnames(rel) <- blues[,2];
                write.table(rel, file=\''.$stats_out_htp_rel_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
                print STDERR Dumper $htp_cmd;
                my $status = system($htp_cmd);
            }
            else {
                $c->stash->{rest} = { error => "The value of $compute_relationship_matrix_from_htp_phenotypes_type htp_pheno_rel_matrix_type is not valid!" };
                return;
            }

            open(my $htp_rel_res, '<', $stats_out_htp_rel_tempfile)
                or die "Could not open file '$stats_out_htp_rel_tempfile' $!";

                print STDERR "Opened $stats_out_htp_rel_tempfile\n";
                my $header_row = <$htp_rel_res>;
                my @header;
                if ($csv->parse($header_row)) {
                    @header = $csv->fields();
                }

                while (my $row = <$htp_rel_res>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }
                    my $stock_id1 = $columns[0];
                    my $counter = 1;
                    foreach my $stock_id2 (@header) {
                        my $val = $columns[$counter];
                        $rel_htp_result_hash{$stock_id1}->{$stock_id2} = $val;
                        $counter++;
                    }
                }
            close($htp_rel_res);

            my $data_rel_htp = '';
            my %result_hash;
            if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                foreach my $s (sort @accession_ids) {
                    foreach my $c (sort @accession_ids) {
                        if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                            my $val = $rel_htp_result_hash{$s}->{$c};
                            if (defined $val and length $val) {
                                $result_hash{$s}->{$c} = $val;
                                $data_rel_htp .= "$s\t$c\t$val\n";
                            }
                        }
                    }
                }
            }
            else {
                foreach my $s (sort @accession_ids) {
                    foreach my $c (sort @accession_ids) {
                        if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                            my $val = $rel_htp_result_hash{$s}->{$c};
                            if (defined $val and length $val) {
                                $result_hash{$s}->{$c} = $val;
                                $result_hash{$c}->{$s} = $val;
                                $data_rel_htp .= "S$s\tS$c\t$val\n";
                                if ($s != $c) {
                                    $data_rel_htp .= "S$c\tS$s\t$val\n";
                                }
                            }
                        }
                    }
                }
            }

            open(my $htp_rel_out, ">", $stats_out_htp_rel_tempfile_out) || die "Can't open file ".$stats_out_htp_rel_tempfile_out;
                print $htp_rel_out $data_rel_htp;
            close($htp_rel_out);

            $grm_file = $stats_out_htp_rel_tempfile_out;
        }
        else {
            $c->stash->{rest} = { error => "The value of $compute_relationship_matrix_from_htp_phenotypes is not valid!" };
            return;
        }
    }

    my ($statistical_ontology_term, $analysis_model_training_data_file_type, $analysis_model_language, $sorted_residual_trait_names_array, $rr_unique_traits_hash, $rr_residual_unique_traits_hash, $statistics_cmd, $cmd_f90, $number_traits, $trait_to_time_map_hash,
    $result_blup_data_original, $result_blup_data_delta_original, $result_blup_spatial_data_original, $result_blup_pe_data_original, $result_blup_pe_data_delta_original, $result_residual_data_original, $result_fitted_data_original, $fixed_effects_original_hash, $rr_genetic_coefficients_original_hash, $rr_temporal_coefficients_original_hash,
    $model_sum_square_residual_original, $genetic_effect_min_original, $genetic_effect_max_original, $env_effect_min_original, $env_effect_max_original, $genetic_effect_sum_square_original, $genetic_effect_sum_original, $env_effect_sum_square_original, $env_effect_sum_original, $residual_sum_square_original, $residual_sum_original,
    $phenotype_data_altered_hash, $data_matrix_altered_array, $data_matrix_phenotypes_altered_array, $phenotype_min_altered, $phenotype_max_altered,
    $result_blup_data_altered, $result_blup_data_delta_altered, $result_blup_spatial_data_altered, $result_blup_pe_data_altered, $result_blup_pe_data_delta_altered, $result_residual_data_altered, $result_fitted_data_altered, $fixed_effects_altered_hash, $rr_genetic_coefficients_altered_hash, $rr_temporal_coefficients_altered_hash,
    $model_sum_square_residual_altered, $genetic_effect_min_altered, $genetic_effect_max_altered, $env_effect_min_altered, $env_effect_max_altered, $genetic_effect_sum_square_altered, $genetic_effect_sum_altered, $env_effect_sum_square_altered, $env_effect_sum_altered, $residual_sum_square_altered, $residual_sum_altered,
    $phenotype_data_altered_env_hash, $data_matrix_altered_env_array, $data_matrix_phenotypes_altered_env_array, $phenotype_min_altered_env, $phenotype_max_altered_env, $env_sim_min, $env_sim_max, $sim_data_hash,
    $result_blup_data_altered_env, $result_blup_data_delta_altered_env, $result_blup_spatial_data_altered_env, $result_blup_pe_data_altered_env, $result_blup_pe_data_delta_altered_env, $result_residual_data_altered_env, $result_fitted_data_altered_env, $fixed_effects_altered_env_hash, $rr_genetic_coefficients_altered_env_hash, $rr_temporal_coefficients_altered_env_hash,
    $model_sum_square_residual_altered_env, $genetic_effect_min_altered_env, $genetic_effect_max_altered_env, $env_effect_min_altered_env, $env_effect_max_altered_env, $genetic_effect_sum_square_altered_env, $genetic_effect_sum_altered_env, $env_effect_sum_square_altered_env, $env_effect_sum_altered_env, $residual_sum_square_altered_env, $residual_sum_altered_env,
    $phenotype_data_altered_env_2_hash, $data_matrix_altered_env_2_array, $data_matrix_phenotypes_altered_env_2_array, $phenotype_min_altered_env_2, $phenotype_max_altered_env_2, $env_sim_min_2, $env_sim_max_2, $sim_data_2_hash,
    $result_blup_data_altered_env_2, $result_blup_data_delta_altered_env_2, $result_blup_spatial_data_altered_env_2, $result_blup_pe_data_altered_env_2, $result_blup_pe_data_delta_altered_env_2, $result_residual_data_altered_env_2, $result_fitted_data_altered_env_2, $fixed_effects_altered_env_2_hash, $rr_genetic_coefficients_altered_env_2_hash, $rr_temporal_coefficients_altered_env_2_hash,
    $model_sum_square_residual_altered_env_2, $genetic_effect_min_altered_env_2, $genetic_effect_max_altered_env_2, $env_effect_min_altered_env_2, $env_effect_max_altered_env_2, $genetic_effect_sum_square_altered_env_2, $genetic_effect_sum_altered_env_2, $env_effect_sum_square_altered_env_2, $env_effect_sum_altered_env_2, $residual_sum_square_altered_env_2, $residual_sum_altered_env_2,
    $phenotype_data_altered_env_3_hash, $data_matrix_altered_env_3_array, $data_matrix_phenotypes_altered_env_3_array, $phenotype_min_altered_env_3, $phenotype_max_altered_env_3, $env_sim_min_3, $env_sim_max_3, $sim_data_3_hash,
    $result_blup_data_altered_env_3, $result_blup_data_delta_altered_env_3, $result_blup_spatial_data_altered_env_3, $result_blup_pe_data_altered_env_3, $result_blup_pe_data_delta_altered_env_3, $result_residual_data_altered_env_3, $result_fitted_data_altered_env_3, $fixed_effects_altered_env_3_hash, $rr_genetic_coefficients_altered_env_3_hash, $rr_temporal_coefficients_altered_env_3_hash,
    $model_sum_square_residual_altered_env_3, $genetic_effect_min_altered_env_3, $genetic_effect_max_altered_env_3, $env_effect_min_altered_env_3, $env_effect_max_altered_env_3, $genetic_effect_sum_square_altered_env_3, $genetic_effect_sum_altered_env_3, $env_effect_sum_square_altered_env_3, $env_effect_sum_altered_env_3, $residual_sum_square_altered_env_3, $residual_sum_altered_env_3,
    $phenotype_data_altered_env_4_hash, $data_matrix_altered_env_4_array, $data_matrix_phenotypes_altered_env_4_array, $phenotype_min_altered_env_4, $phenotype_max_altered_env_4, $env_sim_min_4, $env_sim_max_4, $sim_data_4_hash,
    $result_blup_data_altered_env_4, $result_blup_data_delta_altered_env_4, $result_blup_spatial_data_altered_env_4, $result_blup_pe_data_altered_env_4, $result_blup_pe_data_delta_altered_env_4, $result_residual_data_altered_env_4, $result_fitted_data_altered_env_4, $fixed_effects_altered_env_4_hash, $rr_genetic_coefficients_altered_env_4_hash, $rr_temporal_coefficients_altered_env_4_hash,
    $model_sum_square_residual_altered_env_4, $genetic_effect_min_altered_env_4, $genetic_effect_max_altered_env_4, $env_effect_min_altered_env_4, $env_effect_max_altered_env_4, $genetic_effect_sum_square_altered_env_4, $genetic_effect_sum_altered_env_4, $env_effect_sum_square_altered_env_4, $env_effect_sum_altered_env_4, $residual_sum_square_altered_env_4, $residual_sum_altered_env_4,
    $phenotype_data_altered_env_5_hash, $data_matrix_altered_env_5_array, $data_matrix_phenotypes_altered_env_5_array, $phenotype_min_altered_env_5, $phenotype_max_altered_env_5, $env_sim_min_5, $env_sim_max_5, $sim_data_5_hash,
    $result_blup_data_altered_env_5, $result_blup_data_delta_altered_env_5, $result_blup_spatial_data_altered_env_5, $result_blup_pe_data_altered_env_5, $result_blup_pe_data_delta_altered_env_5, $result_residual_data_altered_env_5, $result_fitted_data_altered_env_5, $fixed_effects_altered_env_5_hash, $rr_genetic_coefficients_altered_env_5_hash, $rr_temporal_coefficients_altered_env_5_hash,
    $model_sum_square_residual_altered_env_5, $genetic_effect_min_altered_env_5, $genetic_effect_max_altered_env_5, $env_effect_min_altered_env_5, $env_effect_max_altered_env_5, $genetic_effect_sum_square_altered_env_5, $genetic_effect_sum_altered_env_5, $env_effect_sum_square_altered_env_5, $env_effect_sum_altered_env_5, $residual_sum_square_altered_env_5, $residual_sum_altered_env_5) = _perform_drone_imagery_analytics($c, $schema, $env_factor, $a_env, $b_env, $ro_env, $row_ro_env, $env_variance_percent, $protocol_id, $statistics_select, $analytics_select, $tolparinv, $use_area_under_curve, $env_simulation, $legendre_order_number, $permanent_environment_structure, \@legendre_coeff_exec, \%trait_name_encoder, \%trait_name_encoder_rev, \%stock_info, \%plot_id_map, \@sorted_trait_names, \%accession_id_factor_map, \@rep_time_factors, \@ind_rep_factors, \@unique_accession_names, \%plot_id_count_map_reverse, \@sorted_scaled_ln_times, \%time_count_map_reverse, \%accession_id_factor_map_reverse, \%seen_times, \%plot_id_factor_map_reverse, \%trait_to_time_map, \@unique_plot_names, \%stock_name_row_col, \%phenotype_data_original, \%plot_rep_time_factor_map, \%stock_row_col, \%stock_row_col_id, \%polynomial_map, \@plot_ids_ordered, $csv, $timestamp, $user_name, $stats_tempfile, $grm_file, $grm_rename_tempfile, $tmp_stats_dir, $stats_out_tempfile, $stats_out_tempfile_row, $stats_out_tempfile_col, $stats_out_tempfile_residual, $stats_out_tempfile_2dspl, $stats_prep2_tempfile, $stats_out_param_tempfile, $parameter_tempfile, $parameter_asreml_tempfile, $stats_tempfile_2, $permanent_environment_structure_tempfile, $permanent_environment_structure_env_tempfile, $permanent_environment_structure_env_tempfile2, $permanent_environment_structure_env_tempfile_mat, $yhat_residual_tempfile, $blupf90_solutions_tempfile, $coeff_genetic_tempfile, $coeff_pe_tempfile, $time_min, $time_max, $header_string, $env_sim_exec, $min_row, $max_row, $min_col, $max_col, $mean_row, $sig_row, $mean_col, $sig_col);
    %trait_to_time_map = %$trait_to_time_map_hash;
    my @sorted_residual_trait_names = @$sorted_residual_trait_names_array;
    my %rr_unique_traits = %$rr_unique_traits_hash;
    my %rr_residual_unique_traits = %$rr_residual_unique_traits_hash;
    my %fixed_effects_original = %$fixed_effects_original_hash;
    my %rr_genetic_coefficients_original = %$rr_genetic_coefficients_original_hash;
    my %rr_temporal_coefficients_original = %$rr_temporal_coefficients_original_hash;
    my %phenotype_data_altered = %$phenotype_data_altered_hash;
    my @data_matrix_altered = @$data_matrix_altered_array;
    my @data_matrix_phenotypes_altered = @$data_matrix_phenotypes_altered_array;
    my %fixed_effects_altered = %$fixed_effects_altered_hash;
    my %rr_genetic_coefficients_altered = %$rr_genetic_coefficients_altered_hash;
    my %rr_temporal_coefficients_altered = %$rr_temporal_coefficients_altered_hash;
    my %phenotype_data_altered_env = %$phenotype_data_altered_env_hash;
    my @data_matrix_altered_env = @$data_matrix_altered_env_array;
    my @data_matrix_phenotypes_altered_env = @$data_matrix_phenotypes_altered_env_array;
    my %sim_data = %$sim_data_hash;
    my %fixed_effects_altered_env = %$fixed_effects_altered_env_hash;
    my %rr_genetic_coefficients_altered_env = %$rr_genetic_coefficients_altered_env_hash;
    my %rr_temporal_coefficients_altered_env = %$rr_temporal_coefficients_altered_env_hash;
    my %phenotype_data_altered_env_2 = %$phenotype_data_altered_env_2_hash;
    my @data_matrix_altered_env_2 = @$data_matrix_altered_env_2_array;
    my @data_matrix_phenotypes_altered_env_2 = @$data_matrix_phenotypes_altered_env_2_array;
    my %sim_data_2 = %$sim_data_2_hash;
    my %fixed_effects_altered_env_2 = %$fixed_effects_altered_env_2_hash;
    my %rr_genetic_coefficients_altered_env_2 = %$rr_genetic_coefficients_altered_env_2_hash;
    my %rr_temporal_coefficients_altered_env_2 = %$rr_temporal_coefficients_altered_env_2_hash;
    my %phenotype_data_altered_env_3 = %$phenotype_data_altered_env_3_hash;
    my @data_matrix_altered_env_3 = @$data_matrix_altered_env_3_array;
    my @data_matrix_phenotypes_altered_env_3 = @$data_matrix_phenotypes_altered_env_3_array;
    my %sim_data_3 = %$sim_data_3_hash;
    my %fixed_effects_altered_env_3 = %$fixed_effects_altered_env_3_hash;
    my %rr_genetic_coefficients_altered_env_3 = %$rr_genetic_coefficients_altered_env_3_hash;
    my %rr_temporal_coefficients_altered_env_3 = %$rr_temporal_coefficients_altered_env_3_hash;
    my %phenotype_data_altered_env_4 = %$phenotype_data_altered_env_4_hash;
    my @data_matrix_altered_env_4 = @$data_matrix_altered_env_4_array;
    my @data_matrix_phenotypes_altered_env_4 = @$data_matrix_phenotypes_altered_env_4_array;
    my %sim_data_4 = %$sim_data_4_hash;
    my %fixed_effects_altered_env_4 = %$fixed_effects_altered_env_4_hash;
    my %rr_genetic_coefficients_altered_env_4 = %$rr_genetic_coefficients_altered_env_4_hash;
    my %rr_temporal_coefficients_altered_env_4 = %$rr_temporal_coefficients_altered_env_4_hash;
    my %phenotype_data_altered_env_5 = %$phenotype_data_altered_env_5_hash;
    my @data_matrix_altered_env_5 = @$data_matrix_altered_env_5_array;
    my @data_matrix_phenotypes_altered_env_5 = @$data_matrix_phenotypes_altered_env_5_array;
    my %sim_data_5 = %$sim_data_5_hash;
    my %fixed_effects_altered_env_5 = %$fixed_effects_altered_env_5_hash;
    my %rr_genetic_coefficients_altered_env_5 = %$rr_genetic_coefficients_altered_env_5_hash;
    my %rr_temporal_coefficients_altered_env_5 = %$rr_temporal_coefficients_altered_env_5_hash;

    $permanent_environment_structure = 'env_corr_structure';

    my ($statistical_ontology_term_4, $analysis_model_training_data_file_type_4, $analysis_model_language_4, $sorted_residual_trait_names_array_4, $rr_unique_traits_hash_4, $rr_residual_unique_traits_hash_4, $statistics_cmd_4, $cmd_f90_4, $number_traits_4, $trait_to_time_map_hash_4,
    $result_blup_data_original_4, $result_blup_data_delta_original_4, $result_blup_spatial_data_original_4, $result_blup_pe_data_original_4, $result_blup_pe_data_delta_original_4, $result_residual_data_original_4, $result_fitted_data_original_4, $fixed_effects_original_hash_4, $rr_genetic_coefficients_original_hash_4, $rr_temporal_coefficients_original_hash_4,
    $model_sum_square_residual_original_4, $genetic_effect_min_original_4, $genetic_effect_max_original_4, $env_effect_min_original_4, $env_effect_max_original_4, $genetic_effect_sum_square_original_4, $genetic_effect_sum_original_4, $env_effect_sum_square_original_4, $env_effect_sum_original_4, $residual_sum_square_original_4, $residual_sum_original_4,
    $phenotype_data_altered_hash_4, $data_matrix_altered_array_4, $data_matrix_phenotypes_altered_array_4, $phenotype_min_altered_4, $phenotype_max_altered_4,
    $result_blup_data_altered_1_4, $result_blup_data_delta_altered_1_4, $result_blup_spatial_data_altered_1_4, $result_blup_pe_data_altered_1_4, $result_blup_pe_data_delta_altered_1_4, $result_residual_data_altered_1_4, $result_fitted_data_altered_1_4, $fixed_effects_altered_hash_1_4, $rr_genetic_coefficients_altered_hash_1_4, $rr_temporal_coefficients_altered_hash_1_4,
    $model_sum_square_residual_altered_1_4, $genetic_effect_min_altered_1_4, $genetic_effect_max_altered_1_4, $env_effect_min_altered_1_4, $env_effect_max_altered_1_4, $genetic_effect_sum_square_altered_1_4, $genetic_effect_sum_altered_1_4, $env_effect_sum_square_altered_1_4, $env_effect_sum_altered_1_4, $residual_sum_square_altered_1_4, $residual_sum_altered_1_4,
    $phenotype_data_altered_env_hash_1_4, $data_matrix_altered_env_array_1_4, $data_matrix_phenotypes_altered_env_array_1_4, $phenotype_min_altered_env_1_4, $phenotype_max_altered_env_1_4, $env_sim_min_1_4, $env_sim_max_1_4, $sim_data_hash_1_4,
    $result_blup_data_altered_env_1_4, $result_blup_data_delta_altered_env_1_4, $result_blup_spatial_data_altered_env_1_4, $result_blup_pe_data_altered_env_1_4, $result_blup_pe_data_delta_altered_env_1_4, $result_residual_data_altered_env_1_4, $result_fitted_data_altered_env_1_4, $fixed_effects_altered_env_hash_1_4, $rr_genetic_coefficients_altered_env_hash_1_4, $rr_temporal_coefficients_altered_env_hash_1_4,
    $model_sum_square_residual_altered_env_1_4, $genetic_effect_min_altered_env_1_4, $genetic_effect_max_altered_env_1_4, $env_effect_min_altered_env_1_4, $env_effect_max_altered_env_1_4, $genetic_effect_sum_square_altered_env_1_4, $genetic_effect_sum_altered_env_1_4, $env_effect_sum_square_altered_env_1_4, $env_effect_sum_altered_env_1_4, $residual_sum_square_altered_env_1_4, $residual_sum_altered_env_1_4,
    $phenotype_data_altered_env_2_hash_4, $data_matrix_altered_env_2_array_4, $data_matrix_phenotypes_altered_env_2_array_4, $phenotype_min_altered_env_2_4, $phenotype_max_altered_env_2_4, $env_sim_min_2_4, $env_sim_max_2_4, $sim_data_2_hash_4,
    $result_blup_data_altered_env_2_4, $result_blup_data_delta_altered_env_2_4, $result_blup_spatial_data_altered_env_2_4, $result_blup_pe_data_altered_env_2_4, $result_blup_pe_data_delta_altered_env_2_4, $result_residual_data_altered_env_2_4, $result_fitted_data_altered_env_2_4, $fixed_effects_altered_env_2_hash_4, $rr_genetic_coefficients_altered_env_2_hash_4, $rr_temporal_coefficients_altered_env_2_hash_4,
    $model_sum_square_residual_altered_env_2_4, $genetic_effect_min_altered_env_2_4, $genetic_effect_max_altered_env_2_4, $env_effect_min_altered_env_2_4, $env_effect_max_altered_env_2_4, $genetic_effect_sum_square_altered_env_2_4, $genetic_effect_sum_altered_env_2_4, $env_effect_sum_square_altered_env_2_4, $env_effect_sum_altered_env_2_4, $residual_sum_square_altered_env_2_4, $residual_sum_altered_env_2_4,
    $phenotype_data_altered_env_3_hash_4, $data_matrix_altered_env_3_array_4, $data_matrix_phenotypes_altered_env_3_array_4, $phenotype_min_altered_env_3_4, $phenotype_max_altered_env_3_4, $env_sim_min_3_4, $env_sim_max_3_4, $sim_data_3_hash_4,
    $result_blup_data_altered_env_3_4, $result_blup_data_delta_altered_env_3_4, $result_blup_spatial_data_altered_env_3_4, $result_blup_pe_data_altered_env_3_4, $result_blup_pe_data_delta_altered_env_3_4, $result_residual_data_altered_env_3_4, $result_fitted_data_altered_env_3_4, $fixed_effects_altered_env_3_hash_4, $rr_genetic_coefficients_altered_env_3_hash_4, $rr_temporal_coefficients_altered_env_3_hash_4,
    $model_sum_square_residual_altered_env_3_4, $genetic_effect_min_altered_env_3_4, $genetic_effect_max_altered_env_3_4, $env_effect_min_altered_env_3_4, $env_effect_max_altered_env_3_4, $genetic_effect_sum_square_altered_env_3_4, $genetic_effect_sum_altered_env_3_4, $env_effect_sum_square_altered_env_3_4, $env_effect_sum_altered_env_3_4, $residual_sum_square_altered_env_3_4, $residual_sum_altered_env_3_4,
    $phenotype_data_altered_env_4_hash_4, $data_matrix_altered_env_4_array_4, $data_matrix_phenotypes_altered_env_4_array_4, $phenotype_min_altered_env_4_4, $phenotype_max_altered_env_4_4, $env_sim_min_4_4, $env_sim_max_4_4, $sim_data_4_hash_4,
    $result_blup_data_altered_env_4_4, $result_blup_data_delta_altered_env_4_4, $result_blup_spatial_data_altered_env_4_4, $result_blup_pe_data_altered_env_4_4, $result_blup_pe_data_delta_altered_env_4_4, $result_residual_data_altered_env_4_4, $result_fitted_data_altered_env_4_4, $fixed_effects_altered_env_4_hash_4, $rr_genetic_coefficients_altered_env_4_hash_4, $rr_temporal_coefficients_altered_env_4_hash_4,
    $model_sum_square_residual_altered_env_4_4, $genetic_effect_min_altered_env_4_4, $genetic_effect_max_altered_env_4_4, $env_effect_min_altered_env_4_4, $env_effect_max_altered_env_4_4, $genetic_effect_sum_square_altered_env_4_4, $genetic_effect_sum_altered_env_4_4, $env_effect_sum_square_altered_env_4_4, $env_effect_sum_altered_env_4_4, $residual_sum_square_altered_env_4_4, $residual_sum_altered_env_4_4,
    $phenotype_data_altered_env_5_hash_4, $data_matrix_altered_env_5_array_4, $data_matrix_phenotypes_altered_env_5_array_4, $phenotype_min_altered_env_5_4, $phenotype_max_altered_env_5_4, $env_sim_min_5_4, $env_sim_max_5_4, $sim_data_5_hash_4,
    $result_blup_data_altered_env_5_4, $result_blup_data_delta_altered_env_5_4, $result_blup_spatial_data_altered_env_5_4, $result_blup_pe_data_altered_env_5_4, $result_blup_pe_data_delta_altered_env_5_4, $result_residual_data_altered_env_5_4, $result_fitted_data_altered_env_5_4, $fixed_effects_altered_env_5_hash_4, $rr_genetic_coefficients_altered_env_5_hash_4, $rr_temporal_coefficients_altered_env_5_hash_4,
    $model_sum_square_residual_altered_env_5_4, $genetic_effect_min_altered_env_5_4, $genetic_effect_max_altered_env_5_4, $env_effect_min_altered_env_5_4, $env_effect_max_altered_env_5_4, $genetic_effect_sum_square_altered_env_5_4, $genetic_effect_sum_altered_env_5_4, $env_effect_sum_square_altered_env_5_4, $env_effect_sum_altered_env_5_4, $residual_sum_square_altered_env_5_4, $residual_sum_altered_env_5_4) = _perform_drone_imagery_analytics($c, $schema, $env_factor, $a_env, $b_env, $ro_env, $row_ro_env, $env_variance_percent, $protocol_id, $statistics_select, $analytics_select, $tolparinv, $use_area_under_curve, $env_simulation, $legendre_order_number, $permanent_environment_structure, \@legendre_coeff_exec, \%trait_name_encoder, \%trait_name_encoder_rev, \%stock_info, \%plot_id_map, \@sorted_trait_names, \%accession_id_factor_map, \@rep_time_factors, \@ind_rep_factors, \@unique_accession_names, \%plot_id_count_map_reverse, \@sorted_scaled_ln_times, \%time_count_map_reverse, \%accession_id_factor_map_reverse, \%seen_times, \%plot_id_factor_map_reverse, \%trait_to_time_map, \@unique_plot_names, \%stock_name_row_col, \%phenotype_data_original, \%plot_rep_time_factor_map, \%stock_row_col, \%stock_row_col_id, \%polynomial_map, \@plot_ids_ordered, $csv, $timestamp, $user_name, $stats_tempfile, $grm_file, $grm_rename_tempfile, $tmp_stats_dir, $stats_out_tempfile, $stats_out_tempfile_row, $stats_out_tempfile_col, $stats_out_tempfile_residual, $stats_out_tempfile_2dspl, $stats_prep2_tempfile, $stats_out_param_tempfile, $parameter_tempfile, $parameter_asreml_tempfile, $stats_tempfile_2, $permanent_environment_structure_tempfile, $permanent_environment_structure_env_tempfile, $permanent_environment_structure_env_tempfile2, $permanent_environment_structure_env_tempfile_mat, $yhat_residual_tempfile, $blupf90_solutions_tempfile, $coeff_genetic_tempfile, $coeff_pe_tempfile, $time_min, $time_max, $header_string, $env_sim_exec, $min_row, $max_row, $min_col, $max_col, $mean_row, $sig_row, $mean_col, $sig_col);
    my @sorted_residual_trait_names_4 = @$sorted_residual_trait_names_array_4;
    my %rr_unique_traits_4 = %$rr_unique_traits_hash_4;
    my %rr_residual_unique_traits_4 = %$rr_residual_unique_traits_hash_4;
    my %fixed_effects_original_4 = %$fixed_effects_original_hash_4;
    my %rr_genetic_coefficients_original_4 = %$rr_genetic_coefficients_original_hash_4;
    my %rr_temporal_coefficients_original_4 = %$rr_temporal_coefficients_original_hash_4;
    my %phenotype_data_altered_4 = %$phenotype_data_altered_hash_4;
    my @data_matrix_altered_4 = @$data_matrix_altered_array_4;
    my @data_matrix_phenotypes_altered_4 = @$data_matrix_phenotypes_altered_array_4;
    my %fixed_effects_altered_1_4 = %$fixed_effects_altered_hash_1_4;
    my %rr_genetic_coefficients_altered_1_4 = %$rr_genetic_coefficients_altered_hash_1_4;
    my %rr_temporal_coefficients_altered_1_4 = %$rr_temporal_coefficients_altered_hash_1_4;
    my %phenotype_data_altered_env_1_4 = %$phenotype_data_altered_env_hash_1_4;
    my @data_matrix_altered_env_1_4 = @$data_matrix_altered_env_array_1_4;
    my @data_matrix_phenotypes_altered_env_1_4 = @$data_matrix_phenotypes_altered_env_array_1_4;
    my %sim_data_1_4 = %$sim_data_hash_1_4;
    my %fixed_effects_altered_env_1_4 = %$fixed_effects_altered_env_hash_1_4;
    my %rr_genetic_coefficients_altered_env_1_4 = %$rr_genetic_coefficients_altered_env_hash_1_4;
    my %rr_temporal_coefficients_altered_env_1_4 = %$rr_temporal_coefficients_altered_env_hash_1_4;
    my %phenotype_data_altered_env_2_4 = %$phenotype_data_altered_env_2_hash_4;
    my @data_matrix_altered_env_2_4 = @$data_matrix_altered_env_2_array_4;
    my @data_matrix_phenotypes_altered_env_2_4 = @$data_matrix_phenotypes_altered_env_2_array_4;
    my %sim_data_2_4 = %$sim_data_2_hash_4;
    my %fixed_effects_altered_env_2_4 = %$fixed_effects_altered_env_2_hash_4;
    my %rr_genetic_coefficients_altered_env_2_4 = %$rr_genetic_coefficients_altered_env_2_hash_4;
    my %rr_temporal_coefficients_altered_env_2_4 = %$rr_temporal_coefficients_altered_env_2_hash_4;
    my %phenotype_data_altered_env_3_4 = %$phenotype_data_altered_env_3_hash_4;
    my @data_matrix_altered_env_3_4 = @$data_matrix_altered_env_3_array_4;
    my @data_matrix_phenotypes_altered_env_3_4 = @$data_matrix_phenotypes_altered_env_3_array_4;
    my %sim_data_3_4 = %$sim_data_3_hash_4;
    my %fixed_effects_altered_env_3_4 = %$fixed_effects_altered_env_3_hash_4;
    my %rr_genetic_coefficients_altered_env_3_4 = %$rr_genetic_coefficients_altered_env_3_hash_4;
    my %rr_temporal_coefficients_altered_env_3_4 = %$rr_temporal_coefficients_altered_env_3_hash_4;
    my %phenotype_data_altered_env_4_4 = %$phenotype_data_altered_env_4_hash_4;
    my @data_matrix_altered_env_4_4 = @$data_matrix_altered_env_4_array_4;
    my @data_matrix_phenotypes_altered_env_4_4 = @$data_matrix_phenotypes_altered_env_4_array_4;
    my %sim_data_4_4 = %$sim_data_4_hash_4;
    my %fixed_effects_altered_env_4_4 = %$fixed_effects_altered_env_4_hash_4;
    my %rr_genetic_coefficients_altered_env_4_4 = %$rr_genetic_coefficients_altered_env_4_hash_4;
    my %rr_temporal_coefficients_altered_env_4_4 = %$rr_temporal_coefficients_altered_env_4_hash_4;
    my %phenotype_data_altered_env_5_4 = %$phenotype_data_altered_env_5_hash_4;
    my @data_matrix_altered_env_5_4 = @$data_matrix_altered_env_5_array_4;
    my @data_matrix_phenotypes_altered_env_5_4 = @$data_matrix_phenotypes_altered_env_5_array_4;
    my %sim_data_5_4 = %$sim_data_5_hash_4;
    my %fixed_effects_altered_env_5_4 = %$fixed_effects_altered_env_5_hash_4;
    my %rr_genetic_coefficients_altered_env_5_4 = %$rr_genetic_coefficients_altered_env_5_hash_4;
    my %rr_temporal_coefficients_altered_env_5_4 = %$rr_temporal_coefficients_altered_env_5_hash_4;

    $statistics_select = 'sommer_grm_spatial_genetic_blups';

    my (%phenotype_data_original_2, @data_matrix_original_2, @data_matrix_phenotypes_original_2);
    my (%trait_name_encoder_2, %trait_name_encoder_rev_2, %seen_days_after_plantings_2, %stock_info_2, %seen_times_2, %seen_trial_ids_2, %trait_to_time_map_2, %trait_composing_info_2, @sorted_trait_names_2, %seen_trait_names_2, %unique_traits_ids_2, @phenotype_header_2, $header_string_2);
    my (@sorted_scaled_ln_times_2, %plot_id_factor_map_reverse_2, %plot_id_count_map_reverse_2, %accession_id_factor_map_2, %accession_id_factor_map_reverse_2, %time_count_map_reverse_2, @rep_time_factors_2, @ind_rep_factors_2, %plot_rep_time_factor_map_2, %seen_rep_times_2, %seen_ind_reps_2, @legs_header_2, %polynomial_map_2);
    my $time_min_2 = 100000000;
    my $time_max_2 = 0;
    my $phenotype_min_original_2 = 1000000000;
    my $phenotype_max_original_2 = -1000000000;

    eval {
        print STDERR "PREPARE ORIGINAL PHENOTYPE FILES 2\n";
        my $phenotypes_search_2 = CXGN::Phenotypes::SearchFactory->instantiate(
            'MaterializedViewTable',
            {
                bcs_schema=>$schema,
                data_level=>'plot',
                trait_list=>$trait_id_list,
                trial_list=>$field_trial_id_list,
                include_timestamp=>0,
                exclude_phenotype_outlier=>0
            }
        );
        my ($data_2, $unique_traits_2) = $phenotypes_search_2->search();
        @sorted_trait_names_2 = sort keys %$unique_traits_2;

        if (scalar(@$data_2) == 0) {
            $c->stash->{rest} = { error => "There are no phenotypes for the trials and traits you have selected!"};
            return;
        }

        foreach my $obs_unit (@$data_2){
            $seen_trial_ids_2{$obs_unit->{trial_id}}++;
            my $germplasm_name = $obs_unit->{germplasm_uniquename};
            my $germplasm_stock_id = $obs_unit->{germplasm_stock_id};
            my $replicate_number = $obs_unit->{obsunit_rep} || '';
            my $block_number = $obs_unit->{obsunit_block} || '';
            my $obsunit_stock_id = $obs_unit->{observationunit_stock_id};
            my $obsunit_stock_uniquename = $obs_unit->{observationunit_uniquename};
            my $row_number = $obs_unit->{obsunit_row_number} || '';
            my $col_number = $obs_unit->{obsunit_col_number} || '';

            $stock_info_2{"S".$germplasm_stock_id} = {
                uniquename => $germplasm_name
            };
            my $observations = $obs_unit->{observations};
            foreach (@$observations){
                my $value = $_->{value};
                my $trait_name = $_->{trait_name};
                $phenotype_data_original_2{$obsunit_stock_uniquename}->{$trait_name} = $value;
                $seen_trait_names_2{$trait_name}++;

                if ($value < $phenotype_min_original_2) {
                    $phenotype_min_original_2 = $value;
                }
                elsif ($value >= $phenotype_max_original_2) {
                    $phenotype_max_original_2 = $value;
                }

                if ($_->{associated_image_project_time_json}) {
                    my $related_time_terms_json = decode_json $_->{associated_image_project_time_json};
                    my $time_days_cvterm = $related_time_terms_json->{day};
                    my $time_term_string = $time_days_cvterm;
                    my $time_days = (split '\|', $time_days_cvterm)[0];
                    my $time_value = (split ' ', $time_days)[1];
                    $seen_days_after_plantings_2{$time_value}++;
                    $trait_to_time_map_2{$trait_name} = $time_value;
                }
            }
        }

        my $trait_name_encoded_2 = 1;
        foreach my $trait_name (@sorted_trait_names_2) {
            if (!exists($trait_name_encoder_2{$trait_name})) {
                my $trait_name_e = 't'.$trait_name_encoded_2;
                $trait_name_encoder_2{$trait_name} = $trait_name_e;
                $trait_name_encoder_rev_2{$trait_name_e} = $trait_name;
                $trait_name_encoded_2++;
            }
        }

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @row = ($replicate, $block, "S".$germplasm_stock_id, $obsunit_stock_id, $row_number, $col_number, $row_number, $col_number);

            foreach my $t (@sorted_trait_names_2) {
                if (defined($phenotype_data_original_2{$p}->{$t})) {
                    push @row, $phenotype_data_original_2{$p}->{$t};
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, 'NA';
                }
            }
            push @data_matrix_original_2, \@row;
        }

        foreach (keys %seen_trial_ids_2){
            my $trial = CXGN::Trial->new({bcs_schema=>$schema, trial_id=>$_});
            my $traits_assayed = $trial->get_traits_assayed('plot', undef, 'time_ontology');
            foreach (@$traits_assayed) {
                $unique_traits_ids_2{$_->[0]} = $_;
            }
        }
        foreach (values %unique_traits_ids_2) {
            foreach my $component (@{$_->[2]}) {
                if (exists($seen_trait_names_2{$_->[1]}) && $component->{cv_type} && $component->{cv_type} eq 'time_ontology') {
                    my $time_term_string = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $component->{cvterm_id}, 'extended');
                    push @{$trait_composing_info_2{$_->[1]}}, $time_term_string;
                }
            }
        }

        @phenotype_header_2 = ("replicate", "block", "id", "plot_id", "rowNumber", "colNumber", "rowNumberFactor", "colNumberFactor");
        foreach (@sorted_trait_names_2) {
            push @phenotype_header_2, $trait_name_encoder_2{$_};
        }
        $header_string_2 = join ',', @phenotype_header_2;

        open($F, ">", $stats_tempfile) || die "Can't open file ".$stats_tempfile;
            print $F $header_string_2."\n";
            foreach (@data_matrix_original_2) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);

        print STDERR Dumper [$phenotype_min_original_2, $phenotype_max_original_2];

        print STDERR "PREPARE RELATIONSHIP MATRIX\n";
        if ($statistics_select eq 'sommer_grm_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_temporal_random_regression_dap_genetic_blups' || $statistics_select eq 'sommer_grm_temporal_random_regression_gdd_genetic_blups' || $statistics_select eq 'sommer_grm_genetic_only_random_regression_dap_genetic_blups'
            || $statistics_select eq 'sommer_grm_genetic_only_random_regression_gdd_genetic_blups' || $statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups'
            || $statistics_select eq 'sommer_grm_genetic_blups') {

            my %seen_accession_stock_ids;
            foreach my $trial_id (@$field_trial_id_list) {
                my $trial = CXGN::Trial->new({ bcs_schema => $schema, trial_id => $trial_id });
                my $accessions = $trial->get_accessions();
                foreach (@$accessions) {
                    $seen_accession_stock_ids{$_->{stock_id}}++;
                }
            }
            my @accession_ids = keys %seen_accession_stock_ids;

            if ($compute_relationship_matrix_from_htp_phenotypes eq 'genotypes') {

                if ($include_pedgiree_info_if_compute_from_parents) {
                    my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
                    my $tmp_arm_dir = $shared_cluster_dir_config."/tmp_download_arm";
                    mkdir $tmp_arm_dir if ! -d $tmp_arm_dir;
                    my ($arm_tempfile_fh, $arm_tempfile) = tempfile("drone_stats_download_arm_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm1_tempfile_fh, $grm1_tempfile) = tempfile("drone_stats_download_grm1_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_temp_tempfile_fh, $grm_out_temp_tempfile) = tempfile("drone_stats_download_grm_temp_out_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_tempfile_fh, $grm_out_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_posdef_tempfile_fh, $grm_out_posdef_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);

                    if (!$protocol_id) {
                        $protocol_id = undef;
                    }

                    my $pedigree_arm = CXGN::Pedigree::ARM->new({
                        bcs_schema=>$schema,
                        arm_temp_file=>$arm_tempfile,
                        people_schema=>$people_schema,
                        accession_id_list=>\@accession_ids,
                        # plot_id_list=>\@plot_id_list,
                        cache_root=>$c->config->{cache_file_path},
                        download_format=>'matrix', #either 'matrix', 'three_column', or 'heatmap'
                    });
                    my ($parent_hash, $stock_ids, $all_accession_stock_ids, $female_stock_ids, $male_stock_ids) = $pedigree_arm->get_arm(
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    # print STDERR Dumper $parent_hash;

                    my $female_geno = CXGN::Genotype::GRM->new({
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm1_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>$female_stock_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>0,
                        download_format=>'three_column_reciprocal'
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    });
                    my $female_grm_data = $female_geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    my @fl = split '\n', $female_grm_data;
                    my %female_parent_grm;
                    foreach (@fl) {
                        my @l = split '\t', $_;
                        $female_parent_grm{$l[0]}->{$l[1]} = $l[2];
                    }
                    # print STDERR Dumper \%female_parent_grm;

                    my $male_geno = CXGN::Genotype::GRM->new({
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm1_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>$male_stock_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>0,
                        download_format=>'three_column_reciprocal'
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    });
                    my $male_grm_data = $male_geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    my @ml = split '\n', $male_grm_data;
                    my %male_parent_grm;
                    foreach (@ml) {
                        my @l = split '\t', $_;
                        $male_parent_grm{$l[0]}->{$l[1]} = $l[2];
                    }
                    # print STDERR Dumper \%male_parent_grm;

                    my %rel_result_hash;
                    foreach my $a1 (@accession_ids) {
                        foreach my $a2 (@accession_ids) {
                            my $female_parent1 = $parent_hash->{$a1}->{female_stock_id};
                            my $male_parent1 = $parent_hash->{$a1}->{male_stock_id};
                            my $female_parent2 = $parent_hash->{$a2}->{female_stock_id};
                            my $male_parent2 = $parent_hash->{$a2}->{male_stock_id};

                            my $female_rel = 0;
                            if ($female_parent1 && $female_parent2 && $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2}) {
                                $female_rel = $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2};
                            }
                            elsif ($female_parent1 && $female_parent2 && $female_parent1 == $female_parent2) {
                                $female_rel = 1;
                            }
                            elsif ($a1 == $a2) {
                                $female_rel = 1;
                            }

                            my $male_rel = 0;
                            if ($male_parent1 && $male_parent2 && $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2}) {
                                $male_rel = $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2};
                            }
                            elsif ($male_parent1 && $male_parent2 && $male_parent1 == $male_parent2) {
                                $male_rel = 1;
                            }
                            elsif ($a1 == $a2) {
                                $male_rel = 1;
                            }
                            # print STDERR "$a1 $a2 $female_rel $male_rel\n";

                            my $rel = 0.5*($female_rel + $male_rel);
                            $rel_result_hash{$a1}->{$a2} = $rel;
                        }
                    }
                    # print STDERR Dumper \%rel_result_hash;

                    my $data = '';
                    my %result_hash;
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $data .= "S$s\tS$c\t$val\n";
                                }
                            }
                        }
                    }

                    # print STDERR Dumper $data;
                    open(my $F2, ">", $grm_out_temp_tempfile) || die "Can't open file ".$grm_out_temp_tempfile;
                        print $F2 $data;
                    close($F2);

                    my $cmd = 'R -e "library(data.table); library(scales); library(tidyr); library(reshape2);
                    three_col <- fread(\''.$grm_out_temp_tempfile.'\', header=FALSE, sep=\'\t\');
                    A_wide <- dcast(three_col, V1~V2, value.var=\'V3\');
                    A_1 <- A_wide[,-1];
                    A_1[is.na(A_1)] <- 0;
                    A <- A_1 + t(A_1);
                    diag(A) <- diag(as.matrix(A_1));
                    E = eigen(A);
                    ev = E\$values;
                    U = E\$vectors;
                    no = dim(A)[1];
                    nev = which(ev < 0);
                    wr = 0;
                    k=length(nev);
                    if(k > 0){
                        p = ev[no - k];
                        B = sum(ev[nev])*2.0;
                        wr = (B*B*100.0)+1;
                        val = ev[nev];
                        ev[nev] = p*(B-val)*(B-val)/wr;
                        A = U%*%diag(ev)%*%t(U);
                    }
                    A <- as.data.frame(A);
                    colnames(A) <- A_wide[,1];
                    A\$stock_id <- A_wide[,1];
                    A_threecol <- melt(A, id.vars = c(\'stock_id\'), measure.vars = A_wide[,1]);
                    A_threecol\$stock_id <- substring(A_threecol\$stock_id, 2);
                    A_threecol\$variable <- substring(A_threecol\$variable, 2);
                    write.table(data.frame(variable = A_threecol\$variable, stock_id = A_threecol\$stock_id, value = A_threecol\$value), file=\''.$grm_out_tempfile.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');"';
                    print STDERR $cmd."\n";
                    my $status = system($cmd);

                    my %rel_pos_def_result_hash;
                    open(my $F3, '<', $grm_out_tempfile)
                        or die "Could not open file '$grm_out_tempfile' $!";

                        print STDERR "Opened $grm_out_tempfile\n";

                        while (my $row = <$F3>) {
                            my @columns;
                            if ($csv->parse($row)) {
                                @columns = $csv->fields();
                            }
                            my $stock_id1 = $columns[0];
                            my $stock_id2 = $columns[1];
                            my $val = $columns[2];
                            $rel_pos_def_result_hash{$stock_id1}->{$stock_id2} = $val;
                        }
                    close($F3);

                    my $data_pos_def = '';
                    if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                        my %result_hash;
                        foreach my $s (sort @accession_ids) {
                            foreach my $c (sort @accession_ids) {
                                if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                    my $val = $rel_pos_def_result_hash{$s}->{$c};
                                    if (defined $val and length $val) {
                                        $result_hash{$s}->{$c} = $val;
                                        $data_pos_def .= "$s\t$c\t$val\n";
                                    }
                                }
                            }
                        }
                    }
                    else {
                        my %result_hash;
                        foreach my $s (sort @accession_ids) {
                            foreach my $c (sort @accession_ids) {
                                if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                    my $val = $rel_pos_def_result_hash{$s}->{$c};
                                    if (defined $val and length $val) {
                                        $result_hash{$s}->{$c} = $val;
                                        $result_hash{$c}->{$s} = $val;
                                        $data_pos_def .= "S$s\tS$c\t$val\n";
                                        if ($s != $c) {
                                            $data_pos_def .= "S$c\tS$s\t$val\n";
                                        }
                                    }
                                }
                            }
                        }
                    }

                    open(my $F4, ">", $grm_out_posdef_tempfile) || die "Can't open file ".$grm_out_posdef_tempfile;
                        print $F4 $data_pos_def;
                    close($F4);

                    $grm_file = $grm_out_posdef_tempfile;
                }
                elsif ($use_parental_grms_if_compute_from_parents) {
                    my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
                    my $tmp_arm_dir = $shared_cluster_dir_config."/tmp_download_arm";
                    mkdir $tmp_arm_dir if ! -d $tmp_arm_dir;
                    my ($arm_tempfile_fh, $arm_tempfile) = tempfile("drone_stats_download_arm_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm1_tempfile_fh, $grm1_tempfile) = tempfile("drone_stats_download_grm1_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_temp_tempfile_fh, $grm_out_temp_tempfile) = tempfile("drone_stats_download_grm_temp_out_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_tempfile_fh, $grm_out_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_posdef_tempfile_fh, $grm_out_posdef_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);

                    if (!$protocol_id) {
                        $protocol_id = undef;
                    }

                    my $pedigree_arm = CXGN::Pedigree::ARM->new({
                        bcs_schema=>$schema,
                        arm_temp_file=>$arm_tempfile,
                        people_schema=>$people_schema,
                        accession_id_list=>\@accession_ids,
                        # plot_id_list=>\@plot_id_list,
                        cache_root=>$c->config->{cache_file_path},
                        download_format=>'matrix', #either 'matrix', 'three_column', or 'heatmap'
                    });
                    my ($parent_hash, $stock_ids, $all_accession_stock_ids, $female_stock_ids, $male_stock_ids) = $pedigree_arm->get_arm(
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    # print STDERR Dumper $parent_hash;

                    my $female_geno = CXGN::Genotype::GRM->new({
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm1_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>$female_stock_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>0,
                        download_format=>'three_column_reciprocal'
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    });
                    my $female_grm_data = $female_geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    my @fl = split '\n', $female_grm_data;
                    my %female_parent_grm;
                    foreach (@fl) {
                        my @l = split '\t', $_;
                        $female_parent_grm{$l[0]}->{$l[1]} = $l[2];
                    }
                    # print STDERR Dumper \%female_parent_grm;

                    my $male_geno = CXGN::Genotype::GRM->new({
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm1_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>$male_stock_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>0,
                        download_format=>'three_column_reciprocal'
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    });
                    my $male_grm_data = $male_geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    my @ml = split '\n', $male_grm_data;
                    my %male_parent_grm;
                    foreach (@ml) {
                        my @l = split '\t', $_;
                        $male_parent_grm{$l[0]}->{$l[1]} = $l[2];
                    }
                    # print STDERR Dumper \%male_parent_grm;

                    my %rel_result_hash;
                    foreach my $a1 (@accession_ids) {
                        foreach my $a2 (@accession_ids) {
                            my $female_parent1 = $parent_hash->{$a1}->{female_stock_id};
                            my $male_parent1 = $parent_hash->{$a1}->{male_stock_id};
                            my $female_parent2 = $parent_hash->{$a2}->{female_stock_id};
                            my $male_parent2 = $parent_hash->{$a2}->{male_stock_id};

                            my $female_rel = 0;
                            if ($female_parent1 && $female_parent2 && $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2}) {
                                $female_rel = $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2};
                            }
                            elsif ($a1 == $a2) {
                                $female_rel = 1;
                            }

                            my $male_rel = 0;
                            if ($male_parent1 && $male_parent2 && $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2}) {
                                $male_rel = $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2};
                            }
                            elsif ($a1 == $a2) {
                                $male_rel = 1;
                            }
                            # print STDERR "$a1 $a2 $female_rel $male_rel\n";

                            my $rel = 0.5*($female_rel + $male_rel);
                            $rel_result_hash{$a1}->{$a2} = $rel;
                        }
                    }
                    # print STDERR Dumper \%rel_result_hash;

                    my $data = '';
                    my %result_hash;
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $data .= "S$s\tS$c\t$val\n";
                                }
                            }
                        }
                    }

                    # print STDERR Dumper $data;
                    open(my $F2, ">", $grm_out_temp_tempfile) || die "Can't open file ".$grm_out_temp_tempfile;
                        print $F2 $data;
                    close($F2);

                    my $cmd = 'R -e "library(data.table); library(scales); library(tidyr); library(reshape2);
                    three_col <- fread(\''.$grm_out_temp_tempfile.'\', header=FALSE, sep=\'\t\');
                    A_wide <- dcast(three_col, V1~V2, value.var=\'V3\');
                    A_1 <- A_wide[,-1];
                    A_1[is.na(A_1)] <- 0;
                    A <- A_1 + t(A_1);
                    diag(A) <- diag(as.matrix(A_1));
                    E = eigen(A);
                    ev = E\$values;
                    U = E\$vectors;
                    no = dim(A)[1];
                    nev = which(ev < 0);
                    wr = 0;
                    k=length(nev);
                    if(k > 0){
                        p = ev[no - k];
                        B = sum(ev[nev])*2.0;
                        wr = (B*B*100.0)+1;
                        val = ev[nev];
                        ev[nev] = p*(B-val)*(B-val)/wr;
                        A = U%*%diag(ev)%*%t(U);
                    }
                    A <- as.data.frame(A);
                    colnames(A) <- A_wide[,1];
                    A\$stock_id <- A_wide[,1];
                    A_threecol <- melt(A, id.vars = c(\'stock_id\'), measure.vars = A_wide[,1]);
                    A_threecol\$stock_id <- substring(A_threecol\$stock_id, 2);
                    A_threecol\$variable <- substring(A_threecol\$variable, 2);
                    write.table(data.frame(variable = A_threecol\$variable, stock_id = A_threecol\$stock_id, value = A_threecol\$value), file=\''.$grm_out_tempfile.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');"';
                    print STDERR $cmd."\n";
                    my $status = system($cmd);

                    my %rel_pos_def_result_hash;
                    open(my $F3, '<', $grm_out_tempfile)
                        or die "Could not open file '$grm_out_tempfile' $!";

                        print STDERR "Opened $grm_out_tempfile\n";

                        while (my $row = <$F3>) {
                            my @columns;
                            if ($csv->parse($row)) {
                                @columns = $csv->fields();
                            }
                            my $stock_id1 = $columns[0];
                            my $stock_id2 = $columns[1];
                            my $val = $columns[2];
                            $rel_pos_def_result_hash{$stock_id1}->{$stock_id2} = $val;
                        }
                    close($F3);

                    my $data_pos_def = '';
                    if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                        my %result_hash;
                        foreach my $s (sort @accession_ids) {
                            foreach my $c (sort @accession_ids) {
                                if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                    my $val = $rel_pos_def_result_hash{$s}->{$c};
                                    if (defined $val and length $val) {
                                        $result_hash{$s}->{$c} = $val;
                                        $data_pos_def .= "$s\t$c\t$val\n";
                                    }
                                }
                            }
                        }
                    }
                    else {
                        my %result_hash;
                        foreach my $s (sort @accession_ids) {
                            foreach my $c (sort @accession_ids) {
                                if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                    my $val = $rel_pos_def_result_hash{$s}->{$c};
                                    if (defined $val and length $val) {
                                        $result_hash{$s}->{$c} = $val;
                                        $result_hash{$c}->{$s} = $val;
                                        $data_pos_def .= "S$s\tS$c\t$val\n";
                                        if ($s != $c) {
                                            $data_pos_def .= "S$c\tS$s\t$val\n";
                                        }
                                    }
                                }
                            }
                        }
                    }

                    open(my $F4, ">", $grm_out_posdef_tempfile) || die "Can't open file ".$grm_out_posdef_tempfile;
                        print $F4 $data_pos_def;
                    close($F4);

                    $grm_file = $grm_out_posdef_tempfile;
                }
                else {
                    my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
                    my $tmp_grm_dir = $shared_cluster_dir_config."/tmp_genotype_download_grm";
                    mkdir $tmp_grm_dir if ! -d $tmp_grm_dir;
                    my ($grm_tempfile_fh, $grm_tempfile) = tempfile("drone_stats_download_grm_XXXXX", DIR=> $tmp_grm_dir);
                    my ($grm_out_tempfile_fh, $grm_out_tempfile) = tempfile("drone_stats_download_grm_XXXXX", DIR=> $tmp_grm_dir);

                    if (!$protocol_id) {
                        $protocol_id = undef;
                    }

                    my $grm_search_params = {
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>\@accession_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>$compute_from_parents,
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    };

                    if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                        $grm_search_params->{download_format} = 'three_column_stock_id_integer';
                    }
                    else {
                        $grm_search_params->{download_format} = 'three_column_reciprocal';
                    }

                    my $geno = CXGN::Genotype::GRM->new($grm_search_params);
                    my $grm_data = $geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );

                    open(my $F2, ">", $grm_out_tempfile) || die "Can't open file ".$grm_out_tempfile;
                        print $F2 $grm_data;
                    close($F2);
                    $grm_file = $grm_out_tempfile;
                }

            }
            elsif ($compute_relationship_matrix_from_htp_phenotypes eq 'htp_phenotypes') {

                my $phenotypes_search = CXGN::Phenotypes::SearchFactory->instantiate(
                    'MaterializedViewTable',
                    {
                        bcs_schema=>$schema,
                        data_level=>'plot',
                        trial_list=>$field_trial_id_list,
                        include_timestamp=>0,
                        exclude_phenotype_outlier=>0
                    }
                );
                my ($data, $unique_traits) = $phenotypes_search->search();

                if (scalar(@$data) == 0) {
                    $c->stash->{rest} = { error => "There are no phenotypes for the trial you have selected!"};
                    return;
                }

                my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
                my $h_time = $schema->storage->dbh()->prepare($q_time);

                my %seen_plot_names_htp_rel;
                my %phenotype_data_htp_rel;
                my %seen_times_htp_rel;
                foreach my $obs_unit (@$data){
                    my $germplasm_name = $obs_unit->{germplasm_uniquename};
                    my $germplasm_stock_id = $obs_unit->{germplasm_stock_id};
                    my $row_number = $obs_unit->{obsunit_row_number} || '';
                    my $col_number = $obs_unit->{obsunit_col_number} || '';
                    my $rep = $obs_unit->{obsunit_rep};
                    my $block = $obs_unit->{obsunit_block};
                    $seen_plot_names_htp_rel{$obs_unit->{observationunit_uniquename}} = $obs_unit;
                    my $observations = $obs_unit->{observations};
                    foreach (@$observations){
                        if ($_->{associated_image_project_time_json}) {
                            my $related_time_terms_json = decode_json $_->{associated_image_project_time_json};

                            my $time_days_cvterm = $related_time_terms_json->{day};
                            my $time_days_term_string = $time_days_cvterm;
                            my $time_days = (split '\|', $time_days_cvterm)[0];
                            my $time_days_value = (split ' ', $time_days)[1];

                            my $time_gdd_value = $related_time_terms_json->{gdd_average_temp} + 0;
                            my $gdd_term_string = "GDD $time_gdd_value";
                            $h_time->execute($gdd_term_string, 'cxgn_time_ontology');
                            my ($gdd_cvterm_id) = $h_time->fetchrow_array();
                            if (!$gdd_cvterm_id) {
                                my $new_gdd_term = $schema->resultset("Cv::Cvterm")->create_with({
                                   name => $gdd_term_string,
                                   cv => 'cxgn_time_ontology'
                                });
                                $gdd_cvterm_id = $new_gdd_term->cvterm_id();
                            }
                            my $time_gdd_term_string = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $gdd_cvterm_id, 'extended');

                            $phenotype_data_htp_rel{$obs_unit->{observationunit_uniquename}}->{$_->{trait_name}} = $_->{value};
                            $seen_times_htp_rel{$_->{trait_name}} = [$time_days_value, $time_days_term_string, $time_gdd_value, $time_gdd_term_string];
                        }
                    }
                }

                my @allowed_standard_htp_values = ('Nonzero Pixel Count', 'Total Pixel Sum', 'Mean Pixel Value', 'Harmonic Mean Pixel Value', 'Median Pixel Value', 'Pixel Variance', 'Pixel Standard Deviation', 'Pixel Population Standard Deviation', 'Minimum Pixel Value', 'Maximum Pixel Value', 'Minority Pixel Value', 'Minority Pixel Count', 'Majority Pixel Value', 'Majority Pixel Count', 'Pixel Group Count');
                my %filtered_seen_times_htp_rel;
                while (my ($t, $time) = each %seen_times_htp_rel) {
                    my $allowed = 0;
                    foreach (@allowed_standard_htp_values) {
                        if (index($t, $_) != -1) {
                            $allowed = 1;
                            last;
                        }
                    }
                    if ($allowed) {
                        $filtered_seen_times_htp_rel{$t} = $time;
                    }
                }

                my @seen_plot_names_htp_rel_sorted = sort keys %seen_plot_names_htp_rel;
                my @filtered_seen_times_htp_rel_sorted = sort keys %filtered_seen_times_htp_rel;

                my @header_htp = ('plot_id', 'plot_name', 'accession_id', 'accession_name', 'rep', 'block');

                my %trait_name_encoder_htp;
                my %trait_name_encoder_rev_htp;
                my $trait_name_encoded_htp = 1;
                my @header_traits_htp;
                foreach my $trait_name (@filtered_seen_times_htp_rel_sorted) {
                    if (!exists($trait_name_encoder_htp{$trait_name})) {
                        my $trait_name_e = 't'.$trait_name_encoded_htp;
                        $trait_name_encoder_htp{$trait_name} = $trait_name_e;
                        $trait_name_encoder_rev_htp{$trait_name_e} = $trait_name;
                        push @header_traits_htp, $trait_name_e;
                        $trait_name_encoded_htp++;
                    }
                }

                my @htp_pheno_matrix;
                if ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'all') {
                    push @header_htp, @header_traits_htp;
                    push @htp_pheno_matrix, \@header_htp;

                    foreach my $p (@seen_plot_names_htp_rel_sorted) {
                        my $obj = $seen_plot_names_htp_rel{$p};
                        my @row = ($obj->{observationunit_stock_id}, $obj->{observationunit_uniquename}, $obj->{germplasm_stock_id}, $obj->{germplasm_uniquename}, $obj->{obsunit_rep}, $obj->{obsunit_block});
                        foreach my $t (@filtered_seen_times_htp_rel_sorted) {
                            my $val = $phenotype_data_htp_rel{$p}->{$t} + 0;
                            push @row, $val;
                        }
                        push @htp_pheno_matrix, \@row;
                    }
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'latest_trait') {
                    my $max_day = 0;
                    foreach (keys %seen_days_after_plantings) {
                        if ($_ + 0 > $max_day) {
                            $max_day = $_;
                        }
                    }

                    foreach my $t (@filtered_seen_times_htp_rel_sorted) {
                        my $day = $filtered_seen_times_htp_rel{$t}->[0];
                        if ($day <= $max_day) {
                            push @header_htp, $t;
                        }
                    }
                    push @htp_pheno_matrix, \@header_htp;

                    foreach my $p (@seen_plot_names_htp_rel_sorted) {
                        my $obj = $seen_plot_names_htp_rel{$p};
                        my @row = ($obj->{observationunit_stock_id}, $obj->{observationunit_uniquename}, $obj->{germplasm_stock_id}, $obj->{germplasm_uniquename}, $obj->{obsunit_rep}, $obj->{obsunit_block});
                        foreach my $t (@filtered_seen_times_htp_rel_sorted) {
                            my $day = $filtered_seen_times_htp_rel{$t}->[0];
                            if ($day <= $max_day) {
                                my $val = $phenotype_data_htp_rel{$p}->{$t} + 0;
                                push @row, $val;
                            }
                        }
                        push @htp_pheno_matrix, \@row;
                    }
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'vegetative') {
                    
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'reproductive') {
                    
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'mature') {
                    
                }
                else {
                    $c->stash->{rest} = { error => "The value of $compute_relationship_matrix_from_htp_phenotypes_time_points htp_pheno_rel_matrix_time_points is not valid!" };
                    return;
                }

                open(my $htp_pheno_f, ">", $stats_out_htp_rel_tempfile_input) || die "Can't open file ".$stats_out_htp_rel_tempfile_input;
                    foreach (@htp_pheno_matrix) {
                        my $line = join "\t", @$_;
                        print $htp_pheno_f $line."\n";
                    }
                close($htp_pheno_f);

                my %rel_htp_result_hash;
                if ($compute_relationship_matrix_from_htp_phenotypes_type eq 'correlations') {
                    my $htp_cmd = 'R -e "library(lme4); library(data.table);
                    mat <- fread(\''.$stats_out_htp_rel_tempfile_input.'\', header=TRUE, sep=\'\t\');
                    mat_agg <- aggregate(mat[, 7:ncol(mat)], list(mat\$accession_id), mean);
                    mat_pheno <- mat_agg[,2:ncol(mat_agg)];
                    cor_mat <- cor(t(mat_pheno));
                    rownames(cor_mat) <- mat_agg[,1];
                    colnames(cor_mat) <- mat_agg[,1];
                    range01 <- function(x){(x-min(x))/(max(x)-min(x))};
                    cor_mat <- range01(cor_mat);
                    write.table(cor_mat, file=\''.$stats_out_htp_rel_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
                    print STDERR Dumper $htp_cmd;
                    my $status = system($htp_cmd);
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_type eq 'blues') {
                    my $htp_cmd = 'R -e "library(lme4); library(data.table);
                    mat <- fread(\''.$stats_out_htp_rel_tempfile_input.'\', header=TRUE, sep=\'\t\');
                    blues <- data.frame(id = seq(1,length(unique(mat\$accession_id))));
                    varlist <- names(mat)[7:ncol(mat)];
                    blues.models <- lapply(varlist, function(x) {
                        tryCatch(
                            lmer(substitute(i ~ 1 + (1|accession_id), list(i = as.name(x))), data = mat, REML = FALSE, control = lmerControl(optimizer =\'Nelder_Mead\', boundary.tol='.$compute_relationship_matrix_from_htp_phenotypes_blues_inversion.' ) ), error=function(e) {}
                        )
                    });
                    counter = 1;
                    for (m in blues.models) {
                        if (!is.null(m)) {
                            blues\$accession_id <- row.names(ranef(m)\$accession_id);
                            blues[,ncol(blues) + 1] <- ranef(m)\$accession_id\$\`(Intercept)\`;
                            colnames(blues)[ncol(blues)] <- varlist[counter];
                        }
                        counter = counter + 1;
                    }
                    blues_vals <- as.matrix(blues[,3:ncol(blues)]);
                    blues_vals <- apply(blues_vals, 2, function(y) (y - mean(y)) / sd(y) ^ as.logical(sd(y)));
                    rel <- (1/ncol(blues_vals)) * (blues_vals %*% t(blues_vals));
                    rownames(rel) <- blues[,2];
                    colnames(rel) <- blues[,2];
                    write.table(rel, file=\''.$stats_out_htp_rel_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
                    print STDERR Dumper $htp_cmd;
                    my $status = system($htp_cmd);
                }
                else {
                    $c->stash->{rest} = { error => "The value of $compute_relationship_matrix_from_htp_phenotypes_type htp_pheno_rel_matrix_type is not valid!" };
                    return;
                }

                open(my $htp_rel_res, '<', $stats_out_htp_rel_tempfile)
                    or die "Could not open file '$stats_out_htp_rel_tempfile' $!";

                    print STDERR "Opened $stats_out_htp_rel_tempfile\n";
                    my $header_row = <$htp_rel_res>;
                    my @header;
                    if ($csv->parse($header_row)) {
                        @header = $csv->fields();
                    }

                    while (my $row = <$htp_rel_res>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $stock_id1 = $columns[0];
                        my $counter = 1;
                        foreach my $stock_id2 (@header) {
                            my $val = $columns[$counter];
                            $rel_htp_result_hash{$stock_id1}->{$stock_id2} = $val;
                            $counter++;
                        }
                    }
                close($htp_rel_res);

                my $data_rel_htp = '';
                my %result_hash;
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_htp_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $data_rel_htp .= "$s\t$c\t$val\n";
                                }
                            }
                        }
                    }
                }
                else {
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_htp_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $result_hash{$c}->{$s} = $val;
                                    $data_rel_htp .= "S$s\tS$c\t$val\n";
                                    if ($s != $c) {
                                        $data_rel_htp .= "S$c\tS$s\t$val\n";
                                    }
                                }
                            }
                        }
                    }
                }

                open(my $htp_rel_out, ">", $stats_out_htp_rel_tempfile_out) || die "Can't open file ".$stats_out_htp_rel_tempfile_out;
                    print $htp_rel_out $data_rel_htp;
                close($htp_rel_out);

                $grm_file = $stats_out_htp_rel_tempfile_out;
            }
            else {
                $c->stash->{rest} = { error => "The value of $compute_relationship_matrix_from_htp_phenotypes is not valid!" };
                return;
            }
        }
    };

    my ($statistical_ontology_term_2, $analysis_model_training_data_file_type_2, $analysis_model_language_2, $sorted_residual_trait_names_array_2, $rr_unique_traits_hash_2, $rr_residual_unique_traits_hash_2, $statistics_cmd_2, $cmd_f90_2, $number_traits_2, $trait_to_time_map_hash_2,
    $result_blup_data_original_2, $result_blup_data_delta_original_2, $result_blup_spatial_data_original_2, $result_blup_pe_data_original_2, $result_blup_pe_data_delta_original_2, $result_residual_data_original_2, $result_fitted_data_original_2, $fixed_effects_original_hash_2, $rr_genetic_coefficients_original_hash_2, $rr_temporal_coefficients_original_hash_2,
    $model_sum_square_residual_original_2, $genetic_effect_min_original_2, $genetic_effect_max_original_2, $env_effect_min_original_2, $env_effect_max_original_2, $genetic_effect_sum_square_original_2, $genetic_effect_sum_original_2, $env_effect_sum_square_original_2, $env_effect_sum_original_2, $residual_sum_square_original_2, $residual_sum_original_2,
    $phenotype_data_altered_hash_2, $data_matrix_altered_array_2, $data_matrix_phenotypes_altered_array_2, $phenotype_min_altered_2, $phenotype_max_altered_2,
    $result_blup_data_altered_1_2, $result_blup_data_delta_altered_1_2, $result_blup_spatial_data_altered_1_2, $result_blup_pe_data_altered_1_2, $result_blup_pe_data_delta_altered_1_2, $result_residual_data_altered_1_2, $result_fitted_data_altered_1_2, $fixed_effects_altered_hash_1_2, $rr_genetic_coefficients_altered_hash_1_2, $rr_temporal_coefficients_altered_hash_1_2,
    $model_sum_square_residual_altered_1_2, $genetic_effect_min_altered_1_2, $genetic_effect_max_altered_1_2, $env_effect_min_altered_1_2, $env_effect_max_altered_1_2, $genetic_effect_sum_square_altered_1_2, $genetic_effect_sum_altered_1_2, $env_effect_sum_square_altered_1_2, $env_effect_sum_altered_1_2, $residual_sum_square_altered_1_2, $residual_sum_altered_1_2,
    $phenotype_data_altered_env_hash_1_2, $data_matrix_altered_env_array_1_2, $data_matrix_phenotypes_altered_env_array_1_2, $phenotype_min_altered_env_1_2, $phenotype_max_altered_env_1_2, $env_sim_min_1_2, $env_sim_max_1_2, $sim_data_hash_1_2,
    $result_blup_data_altered_env_1_2, $result_blup_data_delta_altered_env_1_2, $result_blup_spatial_data_altered_env_1_2, $result_blup_pe_data_altered_env_1_2, $result_blup_pe_data_delta_altered_env_1_2, $result_residual_data_altered_env_1_2, $result_fitted_data_altered_env_1_2, $fixed_effects_altered_env_hash_1_2, $rr_genetic_coefficients_altered_env_hash_1_2, $rr_temporal_coefficients_altered_env_hash_1_2,
    $model_sum_square_residual_altered_env_1_2, $genetic_effect_min_altered_env_1_2, $genetic_effect_max_altered_env_1_2, $env_effect_min_altered_env_1_2, $env_effect_max_altered_env_1_2, $genetic_effect_sum_square_altered_env_1_2, $genetic_effect_sum_altered_env_1_2, $env_effect_sum_square_altered_env_1_2, $env_effect_sum_altered_env_1_2, $residual_sum_square_altered_env_1_2, $residual_sum_altered_env_1_2,
    $phenotype_data_altered_env_2_hash_2, $data_matrix_altered_env_2_array_2, $data_matrix_phenotypes_altered_env_2_array_2, $phenotype_min_altered_env_2_2, $phenotype_max_altered_env_2_2, $env_sim_min_2_2, $env_sim_max_2_2, $sim_data_2_hash_2,
    $result_blup_data_altered_env_2_2, $result_blup_data_delta_altered_env_2_2, $result_blup_spatial_data_altered_env_2_2, $result_blup_pe_data_altered_env_2_2, $result_blup_pe_data_delta_altered_env_2_2, $result_residual_data_altered_env_2_2, $result_fitted_data_altered_env_2_2, $fixed_effects_altered_env_2_hash_2, $rr_genetic_coefficients_altered_env_2_hash_2, $rr_temporal_coefficients_altered_env_2_hash_2,
    $model_sum_square_residual_altered_env_2_2, $genetic_effect_min_altered_env_2_2, $genetic_effect_max_altered_env_2_2, $env_effect_min_altered_env_2_2, $env_effect_max_altered_env_2_2, $genetic_effect_sum_square_altered_env_2_2, $genetic_effect_sum_altered_env_2_2, $env_effect_sum_square_altered_env_2_2, $env_effect_sum_altered_env_2_2, $residual_sum_square_altered_env_2_2, $residual_sum_altered_env_2_2,
    $phenotype_data_altered_env_3_hash_2, $data_matrix_altered_env_3_array_2, $data_matrix_phenotypes_altered_env_3_array_2, $phenotype_min_altered_env_3_2, $phenotype_max_altered_env_3_2, $env_sim_min_3_2, $env_sim_max_3_2, $sim_data_3_hash_2,
    $result_blup_data_altered_env_3_2, $result_blup_data_delta_altered_env_3_2, $result_blup_spatial_data_altered_env_3_2, $result_blup_pe_data_altered_env_3_2, $result_blup_pe_data_delta_altered_env_3_2, $result_residual_data_altered_env_3_2, $result_fitted_data_altered_env_3_2, $fixed_effects_altered_env_3_hash_2, $rr_genetic_coefficients_altered_env_3_hash_2, $rr_temporal_coefficients_altered_env_3_hash_2,
    $model_sum_square_residual_altered_env_3_2, $genetic_effect_min_altered_env_3_2, $genetic_effect_max_altered_env_3_2, $env_effect_min_altered_env_3_2, $env_effect_max_altered_env_3_2, $genetic_effect_sum_square_altered_env_3_2, $genetic_effect_sum_altered_env_3_2, $env_effect_sum_square_altered_env_3_2, $env_effect_sum_altered_env_3_2, $residual_sum_square_altered_env_3_2, $residual_sum_altered_env_3_2,
    $phenotype_data_altered_env_4_hash_2, $data_matrix_altered_env_4_array_2, $data_matrix_phenotypes_altered_env_4_array_2, $phenotype_min_altered_env_4_2, $phenotype_max_altered_env_4_2, $env_sim_min_4_2, $env_sim_max_4_2, $sim_data_4_hash_2,
    $result_blup_data_altered_env_4_2, $result_blup_data_delta_altered_env_4_2, $result_blup_spatial_data_altered_env_4_2, $result_blup_pe_data_altered_env_4_2, $result_blup_pe_data_delta_altered_env_4_2, $result_residual_data_altered_env_4_2, $result_fitted_data_altered_env_4_2, $fixed_effects_altered_env_4_hash_2, $rr_genetic_coefficients_altered_env_4_hash_2, $rr_temporal_coefficients_altered_env_4_hash_2,
    $model_sum_square_residual_altered_env_4_2, $genetic_effect_min_altered_env_4_2, $genetic_effect_max_altered_env_4_2, $env_effect_min_altered_env_4_2, $env_effect_max_altered_env_4_2, $genetic_effect_sum_square_altered_env_4_2, $genetic_effect_sum_altered_env_4_2, $env_effect_sum_square_altered_env_4_2, $env_effect_sum_altered_env_4_2, $residual_sum_square_altered_env_4_2, $residual_sum_altered_env_4_2,
    $phenotype_data_altered_env_5_hash_2, $data_matrix_altered_env_5_array_2, $data_matrix_phenotypes_altered_env_5_array_2, $phenotype_min_altered_env_5_2, $phenotype_max_altered_env_5_2, $env_sim_min_5_2, $env_sim_max_5_2, $sim_data_5_hash_2,
    $result_blup_data_altered_env_5_2, $result_blup_data_delta_altered_env_5_2, $result_blup_spatial_data_altered_env_5_2, $result_blup_pe_data_altered_env_5_2, $result_blup_pe_data_delta_altered_env_5_2, $result_residual_data_altered_env_5_2, $result_fitted_data_altered_env_5_2, $fixed_effects_altered_env_5_hash_2, $rr_genetic_coefficients_altered_env_5_hash_2, $rr_temporal_coefficients_altered_env_5_hash_2,
    $model_sum_square_residual_altered_env_5_2, $genetic_effect_min_altered_env_5_2, $genetic_effect_max_altered_env_5_2, $env_effect_min_altered_env_5_2, $env_effect_max_altered_env_5_2, $genetic_effect_sum_square_altered_env_5_2, $genetic_effect_sum_altered_env_5_2, $env_effect_sum_square_altered_env_5_2, $env_effect_sum_altered_env_5_2, $residual_sum_square_altered_env_5_2, $residual_sum_altered_env_5_2) = _perform_drone_imagery_analytics($c, $schema, $env_factor, $a_env, $b_env, $ro_env, $row_ro_env, $env_variance_percent, $protocol_id, $statistics_select, $analytics_select, $tolparinv, $use_area_under_curve, $env_simulation, $legendre_order_number, $permanent_environment_structure, \@legendre_coeff_exec, \%trait_name_encoder_2, \%trait_name_encoder_rev_2, \%stock_info_2, \%plot_id_map, \@sorted_trait_names_2, \%accession_id_factor_map, \@rep_time_factors, \@ind_rep_factors, \@unique_accession_names, \%plot_id_count_map_reverse, \@sorted_scaled_ln_times, \%time_count_map_reverse, \%accession_id_factor_map_reverse, \%seen_times, \%plot_id_factor_map_reverse, \%trait_to_time_map, \@unique_plot_names, \%stock_name_row_col, \%phenotype_data_original_2, \%plot_rep_time_factor_map, \%stock_row_col, \%stock_row_col_id, \%polynomial_map, \@plot_ids_ordered, $csv, $timestamp, $user_name, $stats_tempfile, $grm_file, $grm_rename_tempfile, $tmp_stats_dir, $stats_out_tempfile, $stats_out_tempfile_row, $stats_out_tempfile_col, $stats_out_tempfile_residual, $stats_out_tempfile_2dspl, $stats_prep2_tempfile, $stats_out_param_tempfile, $parameter_tempfile, $parameter_asreml_tempfile, $stats_tempfile_2, $permanent_environment_structure_tempfile, $permanent_environment_structure_env_tempfile, $permanent_environment_structure_env_tempfile2, $permanent_environment_structure_env_tempfile_mat, $yhat_residual_tempfile, $blupf90_solutions_tempfile, $coeff_genetic_tempfile, $coeff_pe_tempfile, $time_min, $time_max, $header_string_2, $env_sim_exec, $min_row, $max_row, $min_col, $max_col, $mean_row, $sig_row, $mean_col, $sig_col);
    %trait_to_time_map_2 = %$trait_to_time_map_hash_2;
    my @sorted_residual_trait_names_2 = @$sorted_residual_trait_names_array_2;
    my %rr_unique_traits_2 = %$rr_unique_traits_hash_2;
    my %rr_residual_unique_traits_2 = %$rr_residual_unique_traits_hash_2;
    my %fixed_effects_original_2 = %$fixed_effects_original_hash_2;
    my %rr_genetic_coefficients_original_2 = %$rr_genetic_coefficients_original_hash_2;
    my %rr_temporal_coefficients_original_2 = %$rr_temporal_coefficients_original_hash_2;
    my %phenotype_data_altered_2 = %$phenotype_data_altered_hash_2;
    my @data_matrix_altered_2 = @$data_matrix_altered_array_2;
    my @data_matrix_phenotypes_altered_2 = @$data_matrix_phenotypes_altered_array_2;
    my %fixed_effects_altered_1_2 = %$fixed_effects_altered_hash_1_2;
    my %rr_genetic_coefficients_altered_1_2 = %$rr_genetic_coefficients_altered_hash_1_2;
    my %rr_temporal_coefficients_altered_1_2 = %$rr_temporal_coefficients_altered_hash_1_2;
    my %phenotype_data_altered_env_1_2 = %$phenotype_data_altered_env_hash_1_2;
    my @data_matrix_altered_env_1_2 = @$data_matrix_altered_env_array_1_2;
    my @data_matrix_phenotypes_altered_env_1_2 = @$data_matrix_phenotypes_altered_env_array_1_2;
    my %sim_data_1_2 = %$sim_data_hash_1_2;
    my %fixed_effects_altered_env_1_2 = %$fixed_effects_altered_env_hash_1_2;
    my %rr_genetic_coefficients_altered_env_1_2 = %$rr_genetic_coefficients_altered_env_hash_1_2;
    my %rr_temporal_coefficients_altered_env_1_2 = %$rr_temporal_coefficients_altered_env_hash_1_2;
    my %phenotype_data_altered_env_2_2 = %$phenotype_data_altered_env_2_hash_2;
    my @data_matrix_altered_env_2_2 = @$data_matrix_altered_env_2_array_2;
    my @data_matrix_phenotypes_altered_env_2_2 = @$data_matrix_phenotypes_altered_env_2_array_2;
    my %sim_data_2_2 = %$sim_data_2_hash_2;
    my %fixed_effects_altered_env_2_2 = %$fixed_effects_altered_env_2_hash_2;
    my %rr_genetic_coefficients_altered_env_2_2 = %$rr_genetic_coefficients_altered_env_2_hash_2;
    my %rr_temporal_coefficients_altered_env_2_2 = %$rr_temporal_coefficients_altered_env_2_hash_2;
    my %phenotype_data_altered_env_3_2 = %$phenotype_data_altered_env_3_hash_2;
    my @data_matrix_altered_env_3_2 = @$data_matrix_altered_env_3_array_2;
    my @data_matrix_phenotypes_altered_env_3_2 = @$data_matrix_phenotypes_altered_env_3_array_2;
    my %sim_data_3_2 = %$sim_data_3_hash_2;
    my %fixed_effects_altered_env_3_2 = %$fixed_effects_altered_env_3_hash_2;
    my %rr_genetic_coefficients_altered_env_3_2 = %$rr_genetic_coefficients_altered_env_3_hash_2;
    my %rr_temporal_coefficients_altered_env_3_2 = %$rr_temporal_coefficients_altered_env_3_hash_2;
    my %phenotype_data_altered_env_4_2 = %$phenotype_data_altered_env_4_hash_2;
    my @data_matrix_altered_env_4_2 = @$data_matrix_altered_env_4_array_2;
    my @data_matrix_phenotypes_altered_env_4_2 = @$data_matrix_phenotypes_altered_env_4_array_2;
    my %sim_data_4_2 = %$sim_data_4_hash_2;
    my %fixed_effects_altered_env_4_2 = %$fixed_effects_altered_env_4_hash_2;
    my %rr_genetic_coefficients_altered_env_4_2 = %$rr_genetic_coefficients_altered_env_4_hash_2;
    my %rr_temporal_coefficients_altered_env_4_2 = %$rr_temporal_coefficients_altered_env_4_hash_2;
    my %phenotype_data_altered_env_5_2 = %$phenotype_data_altered_env_5_hash_2;
    my @data_matrix_altered_env_5_2 = @$data_matrix_altered_env_5_array_2;
    my @data_matrix_phenotypes_altered_env_5_2 = @$data_matrix_phenotypes_altered_env_5_array_2;
    my %sim_data_5_2 = %$sim_data_5_hash_2;
    my %fixed_effects_altered_env_5_2 = %$fixed_effects_altered_env_5_hash_2;
    my %rr_genetic_coefficients_altered_env_5_2 = %$rr_genetic_coefficients_altered_env_5_hash_2;
    my %rr_temporal_coefficients_altered_env_5_2 = %$rr_temporal_coefficients_altered_env_5_hash_2;

    $statistics_select = 'sommer_grm_univariate_spatial_genetic_blups';

    my ($statistical_ontology_term_3, $analysis_model_training_data_file_type_3, $analysis_model_language_3, $sorted_residual_trait_names_array_3, $rr_unique_traits_hash_3, $rr_residual_unique_traits_hash_3, $statistics_cmd_3, $cmd_f90_3, $number_traits_3, $trait_to_time_map_hash_3,
    $result_blup_data_original_3, $result_blup_data_delta_original_3, $result_blup_spatial_data_original_3, $result_blup_pe_data_original_3, $result_blup_pe_data_delta_original_3, $result_residual_data_original_3, $result_fitted_data_original_3, $fixed_effects_original_hash_3, $rr_genetic_coefficients_original_hash_3, $rr_temporal_coefficients_original_hash_3,
    $model_sum_square_residual_original_3, $genetic_effect_min_original_3, $genetic_effect_max_original_3, $env_effect_min_original_3, $env_effect_max_original_3, $genetic_effect_sum_square_original_3, $genetic_effect_sum_original_3, $env_effect_sum_square_original_3, $env_effect_sum_original_3, $residual_sum_square_original_3, $residual_sum_original_3,
    $phenotype_data_altered_hash_3, $data_matrix_altered_array_3, $data_matrix_phenotypes_altered_array_3, $phenotype_min_altered_3, $phenotype_max_altered_3,
    $result_blup_data_altered_1_3, $result_blup_data_delta_altered_1_3, $result_blup_spatial_data_altered_1_3, $result_blup_pe_data_altered_1_3, $result_blup_pe_data_delta_altered_1_3, $result_residual_data_altered_1_3, $result_fitted_data_altered_1_3, $fixed_effects_altered_hash_1_3, $rr_genetic_coefficients_altered_hash_1_3, $rr_temporal_coefficients_altered_hash_1_3,
    $model_sum_square_residual_altered_1_3, $genetic_effect_min_altered_1_3, $genetic_effect_max_altered_1_3, $env_effect_min_altered_1_3, $env_effect_max_altered_1_3, $genetic_effect_sum_square_altered_1_3, $genetic_effect_sum_altered_1_3, $env_effect_sum_square_altered_1_3, $env_effect_sum_altered_1_3, $residual_sum_square_altered_1_3, $residual_sum_altered_1_3,
    $phenotype_data_altered_env_hash_1_3, $data_matrix_altered_env_array_1_3, $data_matrix_phenotypes_altered_env_array_1_3, $phenotype_min_altered_env_1_3, $phenotype_max_altered_env_1_3, $env_sim_min_1_3, $env_sim_max_1_3, $sim_data_hash_1_3,
    $result_blup_data_altered_env_1_3, $result_blup_data_delta_altered_env_1_3, $result_blup_spatial_data_altered_env_1_3, $result_blup_pe_data_altered_env_1_3, $result_blup_pe_data_delta_altered_env_1_3, $result_residual_data_altered_env_1_3, $result_fitted_data_altered_env_1_3, $fixed_effects_altered_env_hash_1_3, $rr_genetic_coefficients_altered_env_hash_1_3, $rr_temporal_coefficients_altered_env_hash_1_3,
    $model_sum_square_residual_altered_env_1_3, $genetic_effect_min_altered_env_1_3, $genetic_effect_max_altered_env_1_3, $env_effect_min_altered_env_1_3, $env_effect_max_altered_env_1_3, $genetic_effect_sum_square_altered_env_1_3, $genetic_effect_sum_altered_env_1_3, $env_effect_sum_square_altered_env_1_3, $env_effect_sum_altered_env_1_3, $residual_sum_square_altered_env_1_3, $residual_sum_altered_env_1_3,
    $phenotype_data_altered_env_2_hash_3, $data_matrix_altered_env_2_array_3, $data_matrix_phenotypes_altered_env_2_array_3, $phenotype_min_altered_env_2_3, $phenotype_max_altered_env_2_3, $env_sim_min_2_3, $env_sim_max_2_3, $sim_data_2_hash_3,
    $result_blup_data_altered_env_2_3, $result_blup_data_delta_altered_env_2_3, $result_blup_spatial_data_altered_env_2_3, $result_blup_pe_data_altered_env_2_3, $result_blup_pe_data_delta_altered_env_2_3, $result_residual_data_altered_env_2_3, $result_fitted_data_altered_env_2_3, $fixed_effects_altered_env_2_hash_3, $rr_genetic_coefficients_altered_env_2_hash_3, $rr_temporal_coefficients_altered_env_2_hash_3,
    $model_sum_square_residual_altered_env_2_3, $genetic_effect_min_altered_env_2_3, $genetic_effect_max_altered_env_2_3, $env_effect_min_altered_env_2_3, $env_effect_max_altered_env_2_3, $genetic_effect_sum_square_altered_env_2_3, $genetic_effect_sum_altered_env_2_3, $env_effect_sum_square_altered_env_2_3, $env_effect_sum_altered_env_2_3, $residual_sum_square_altered_env_2_3, $residual_sum_altered_env_2_3,
    $phenotype_data_altered_env_3_hash_3, $data_matrix_altered_env_3_array_3, $data_matrix_phenotypes_altered_env_3_array_3, $phenotype_min_altered_env_3_3, $phenotype_max_altered_env_3_3, $env_sim_min_3_3, $env_sim_max_3_3, $sim_data_3_hash_3,
    $result_blup_data_altered_env_3_3, $result_blup_data_delta_altered_env_3_3, $result_blup_spatial_data_altered_env_3_3, $result_blup_pe_data_altered_env_3_3, $result_blup_pe_data_delta_altered_env_3_3, $result_residual_data_altered_env_3_3, $result_fitted_data_altered_env_3_3, $fixed_effects_altered_env_3_hash_3, $rr_genetic_coefficients_altered_env_3_hash_3, $rr_temporal_coefficients_altered_env_3_hash_3,
    $model_sum_square_residual_altered_env_3_3, $genetic_effect_min_altered_env_3_3, $genetic_effect_max_altered_env_3_3, $env_effect_min_altered_env_3_3, $env_effect_max_altered_env_3_3, $genetic_effect_sum_square_altered_env_3_3, $genetic_effect_sum_altered_env_3_3, $env_effect_sum_square_altered_env_3_3, $env_effect_sum_altered_env_3_3, $residual_sum_square_altered_env_3_3, $residual_sum_altered_env_3_3,
    $phenotype_data_altered_env_4_hash_3, $data_matrix_altered_env_4_array_3, $data_matrix_phenotypes_altered_env_4_array_3, $phenotype_min_altered_env_4_3, $phenotype_max_altered_env_4_3, $env_sim_min_4_3, $env_sim_max_4_3, $sim_data_4_hash_3,
    $result_blup_data_altered_env_4_3, $result_blup_data_delta_altered_env_4_3, $result_blup_spatial_data_altered_env_4_3, $result_blup_pe_data_altered_env_4_3, $result_blup_pe_data_delta_altered_env_4_3, $result_residual_data_altered_env_4_3, $result_fitted_data_altered_env_4_3, $fixed_effects_altered_env_4_hash_3, $rr_genetic_coefficients_altered_env_4_hash_3, $rr_temporal_coefficients_altered_env_4_hash_3,
    $model_sum_square_residual_altered_env_4_3, $genetic_effect_min_altered_env_4_3, $genetic_effect_max_altered_env_4_3, $env_effect_min_altered_env_4_3, $env_effect_max_altered_env_4_3, $genetic_effect_sum_square_altered_env_4_3, $genetic_effect_sum_altered_env_4_3, $env_effect_sum_square_altered_env_4_3, $env_effect_sum_altered_env_4_3, $residual_sum_square_altered_env_4_3, $residual_sum_altered_env_4_3,
    $phenotype_data_altered_env_5_hash_3, $data_matrix_altered_env_5_array_3, $data_matrix_phenotypes_altered_env_5_array_3, $phenotype_min_altered_env_5_3, $phenotype_max_altered_env_5_3, $env_sim_min_5_3, $env_sim_max_5_3, $sim_data_5_hash_3,
    $result_blup_data_altered_env_5_3, $result_blup_data_delta_altered_env_5_3, $result_blup_spatial_data_altered_env_5_3, $result_blup_pe_data_altered_env_5_3, $result_blup_pe_data_delta_altered_env_5_3, $result_residual_data_altered_env_5_3, $result_fitted_data_altered_env_5_3, $fixed_effects_altered_env_5_hash_3, $rr_genetic_coefficients_altered_env_5_hash_3, $rr_temporal_coefficients_altered_env_5_hash_3,
    $model_sum_square_residual_altered_env_5_3, $genetic_effect_min_altered_env_5_3, $genetic_effect_max_altered_env_5_3, $env_effect_min_altered_env_5_3, $env_effect_max_altered_env_5_3, $genetic_effect_sum_square_altered_env_5_3, $genetic_effect_sum_altered_env_5_3, $env_effect_sum_square_altered_env_5_3, $env_effect_sum_altered_env_5_3, $residual_sum_square_altered_env_5_3, $residual_sum_altered_env_5_3) = _perform_drone_imagery_analytics($c, $schema, $env_factor, $a_env, $b_env, $ro_env, $row_ro_env, $env_variance_percent, $protocol_id, $statistics_select, $analytics_select, $tolparinv, $use_area_under_curve, $env_simulation, $legendre_order_number, $permanent_environment_structure, \@legendre_coeff_exec, \%trait_name_encoder_2, \%trait_name_encoder_rev_2, \%stock_info_2, \%plot_id_map, \@sorted_trait_names_2, \%accession_id_factor_map, \@rep_time_factors, \@ind_rep_factors, \@unique_accession_names, \%plot_id_count_map_reverse, \@sorted_scaled_ln_times, \%time_count_map_reverse, \%accession_id_factor_map_reverse, \%seen_times, \%plot_id_factor_map_reverse, \%trait_to_time_map, \@unique_plot_names, \%stock_name_row_col, \%phenotype_data_original_2, \%plot_rep_time_factor_map, \%stock_row_col, \%stock_row_col_id, \%polynomial_map, \@plot_ids_ordered, $csv, $timestamp, $user_name, $stats_tempfile, $grm_file, $grm_rename_tempfile, $tmp_stats_dir, $stats_out_tempfile, $stats_out_tempfile_row, $stats_out_tempfile_col, $stats_out_tempfile_residual, $stats_out_tempfile_2dspl, $stats_prep2_tempfile, $stats_out_param_tempfile, $parameter_tempfile, $parameter_asreml_tempfile, $stats_tempfile_2, $permanent_environment_structure_tempfile, $permanent_environment_structure_env_tempfile, $permanent_environment_structure_env_tempfile2, $permanent_environment_structure_env_tempfile_mat, $yhat_residual_tempfile, $blupf90_solutions_tempfile, $coeff_genetic_tempfile, $coeff_pe_tempfile, $time_min, $time_max, $header_string_2, $env_sim_exec, $min_row, $max_row, $min_col, $max_col, $mean_row, $sig_row, $mean_col, $sig_col);
    my @sorted_residual_trait_names_3 = @$sorted_residual_trait_names_array_3;
    my %rr_unique_traits_3 = %$rr_unique_traits_hash_3;
    my %rr_residual_unique_traits_3 = %$rr_residual_unique_traits_hash_3;
    my %fixed_effects_original_3 = %$fixed_effects_original_hash_3;
    my %rr_genetic_coefficients_original_3 = %$rr_genetic_coefficients_original_hash_3;
    my %rr_temporal_coefficients_original_3 = %$rr_temporal_coefficients_original_hash_3;
    my %phenotype_data_altered_3 = %$phenotype_data_altered_hash_3;
    my @data_matrix_altered_3 = @$data_matrix_altered_array_3;
    my @data_matrix_phenotypes_altered_3 = @$data_matrix_phenotypes_altered_array_3;
    my %fixed_effects_altered_1_3 = %$fixed_effects_altered_hash_1_3;
    my %rr_genetic_coefficients_altered_1_3 = %$rr_genetic_coefficients_altered_hash_1_3;
    my %rr_temporal_coefficients_altered_1_3 = %$rr_temporal_coefficients_altered_hash_1_3;
    my %phenotype_data_altered_env_1_3 = %$phenotype_data_altered_env_hash_1_3;
    my @data_matrix_altered_env_1_3 = @$data_matrix_altered_env_array_1_3;
    my @data_matrix_phenotypes_altered_env_1_3 = @$data_matrix_phenotypes_altered_env_array_1_3;
    my %sim_data_1_3 = %$sim_data_hash_1_3;
    my %fixed_effects_altered_env_1_3 = %$fixed_effects_altered_env_hash_1_3;
    my %rr_genetic_coefficients_altered_env_1_3 = %$rr_genetic_coefficients_altered_env_hash_1_3;
    my %rr_temporal_coefficients_altered_env_1_3 = %$rr_temporal_coefficients_altered_env_hash_1_3;
    my %phenotype_data_altered_env_2_3 = %$phenotype_data_altered_env_2_hash_3;
    my @data_matrix_altered_env_2_3 = @$data_matrix_altered_env_2_array_3;
    my @data_matrix_phenotypes_altered_env_2_3 = @$data_matrix_phenotypes_altered_env_2_array_3;
    my %sim_data_2_3 = %$sim_data_2_hash_3;
    my %fixed_effects_altered_env_2_3 = %$fixed_effects_altered_env_2_hash_3;
    my %rr_genetic_coefficients_altered_env_2_3 = %$rr_genetic_coefficients_altered_env_2_hash_3;
    my %rr_temporal_coefficients_altered_env_2_3 = %$rr_temporal_coefficients_altered_env_2_hash_3;
    my %phenotype_data_altered_env_3_3 = %$phenotype_data_altered_env_3_hash_3;
    my @data_matrix_altered_env_3_3 = @$data_matrix_altered_env_3_array_3;
    my @data_matrix_phenotypes_altered_env_3_3 = @$data_matrix_phenotypes_altered_env_3_array_3;
    my %sim_data_3_3 = %$sim_data_3_hash_3;
    my %fixed_effects_altered_env_3_3 = %$fixed_effects_altered_env_3_hash_3;
    my %rr_genetic_coefficients_altered_env_3_3 = %$rr_genetic_coefficients_altered_env_3_hash_3;
    my %rr_temporal_coefficients_altered_env_3_3 = %$rr_temporal_coefficients_altered_env_3_hash_3;
    my %phenotype_data_altered_env_4_3 = %$phenotype_data_altered_env_4_hash_3;
    my @data_matrix_altered_env_4_3 = @$data_matrix_altered_env_4_array_3;
    my @data_matrix_phenotypes_altered_env_4_3 = @$data_matrix_phenotypes_altered_env_4_array_3;
    my %sim_data_4_3 = %$sim_data_4_hash_3;
    my %fixed_effects_altered_env_4_3 = %$fixed_effects_altered_env_4_hash_3;
    my %rr_genetic_coefficients_altered_env_4_3 = %$rr_genetic_coefficients_altered_env_4_hash_3;
    my %rr_temporal_coefficients_altered_env_4_3 = %$rr_temporal_coefficients_altered_env_4_hash_3;
    my %phenotype_data_altered_env_5_3 = %$phenotype_data_altered_env_5_hash_3;
    my @data_matrix_altered_env_5_3 = @$data_matrix_altered_env_5_array_3;
    my @data_matrix_phenotypes_altered_env_5_3 = @$data_matrix_phenotypes_altered_env_5_array_3;
    my %sim_data_5_3 = %$sim_data_5_hash_3;
    my %fixed_effects_altered_env_5_3 = %$fixed_effects_altered_env_5_hash_3;
    my %rr_genetic_coefficients_altered_env_5_3 = %$rr_genetic_coefficients_altered_env_5_hash_3;
    my %rr_temporal_coefficients_altered_env_5_3 = %$rr_temporal_coefficients_altered_env_5_hash_3;

    $statistics_select = 'asreml_grm_univariate_spatial_genetic_blups';
    my $return_inverse_matrix = 1;

    my (%phenotype_data_original_5, @data_matrix_original_5, @data_matrix_phenotypes_original_5);
    my (%trait_name_encoder_5, %trait_name_encoder_rev_5, %seen_days_after_plantings_5, %stock_info_5, %seen_times_5, %seen_trial_ids_5, %trait_to_time_map_5, %trait_composing_info_5, @sorted_trait_names_5, %seen_trait_names_5, %unique_traits_ids_5, @phenotype_header_5, $header_string_5);
    my (@sorted_scaled_ln_times_5, %plot_id_factor_map_reverse_5, %plot_id_count_map_reverse_5, %accession_id_factor_map_5, %accession_id_factor_map_reverse_5, %time_count_map_reverse_5, @rep_time_factors_5, @ind_rep_factors_5, %plot_rep_time_factor_map_5, %seen_rep_times_5, %seen_ind_reps_5, @legs_header_5, %polynomial_map_5);
    my $time_min_5 = 100000000;
    my $time_max_5 = 0;
    my $phenotype_min_original_5 = 1000000000;
    my $phenotype_max_original_5 = -1000000000;

    eval {
        print STDERR "PREPARE ORIGINAL PHENOTYPE FILES 5\n";
        my $phenotypes_search_5 = CXGN::Phenotypes::SearchFactory->instantiate(
            'MaterializedViewTable',
            {
                bcs_schema=>$schema,
                data_level=>'plot',
                trait_list=>$trait_id_list,
                trial_list=>$field_trial_id_list,
                include_timestamp=>0,
                exclude_phenotype_outlier=>0
            }
        );
        my ($data_5, $unique_traits_5) = $phenotypes_search_5->search();
        @sorted_trait_names_5 = sort keys %$unique_traits_5;

        if (scalar(@$data_5) == 0) {
            $c->stash->{rest} = { error => "There are no phenotypes for the trials and traits you have selected!"};
            return;
        }

        foreach my $obs_unit (@$data_5){
            my $germplasm_name = $obs_unit->{germplasm_uniquename};
            my $germplasm_stock_id = $obs_unit->{germplasm_stock_id};
            my $replicate_number = $obs_unit->{obsunit_rep} || '';
            my $block_number = $obs_unit->{obsunit_block} || '';
            my $obsunit_stock_id = $obs_unit->{observationunit_stock_id};
            my $obsunit_stock_uniquename = $obs_unit->{observationunit_uniquename};
            my $row_number = $obs_unit->{obsunit_row_number} || '';
            my $col_number = $obs_unit->{obsunit_col_number} || '';

            $stock_info_5{$germplasm_stock_id} = {
                uniquename => $germplasm_name
            };
            my $observations = $obs_unit->{observations};
            foreach (@$observations){
                if ($_->{associated_image_project_time_json}) {
                    my $related_time_terms_json = decode_json $_->{associated_image_project_time_json};
                    my $time;
                    my $time_term_string = '';
                    if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                        $time = $related_time_terms_json->{gdd_average_temp} + 0;

                        my $gdd_term_string = "GDD $time";
                        $h_time->execute($gdd_term_string, 'cxgn_time_ontology');
                        my ($gdd_cvterm_id) = $h_time->fetchrow_array();

                        if (!$gdd_cvterm_id) {
                            my $new_gdd_term = $schema->resultset("Cv::Cvterm")->create_with({
                               name => $gdd_term_string,
                               cv => 'cxgn_time_ontology'
                            });
                            $gdd_cvterm_id = $new_gdd_term->cvterm_id();
                        }
                        $time_term_string = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $gdd_cvterm_id, 'extended');
                    }
                    elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
                        my $time_days_cvterm = $related_time_terms_json->{day};
                        $time_term_string = $time_days_cvterm;
                        my $time_days = (split '\|', $time_days_cvterm)[0];
                        $time = (split ' ', $time_days)[1] + 0;

                        $seen_days_after_plantings{$time}++;
                    }

                    my $value = $_->{value};
                    my $trait_name = $_->{trait_name};
                    $phenotype_data_original_5{$obsunit_stock_uniquename}->{$time} = $value;
                    $seen_times_5{$time} = $trait_name;
                    $seen_trait_names_5{$trait_name} = $time_term_string;
                    $trait_to_time_map_5{$trait_name} = $time;

                    if ($value < $phenotype_min_original_5) {
                        $phenotype_min_original_5 = $value;
                    }
                    elsif ($value >= $phenotype_max_original_5) {
                        $phenotype_max_original_5 = $value;
                    }
                }
            }
        }
        if (scalar(keys %seen_times_5) == 0) {
            $c->stash->{rest} = { error => "There are no phenotypes with associated days after planting time associated to the traits you have selected!"};
            return;
        }

        @sorted_trait_names_5 = sort {$a <=> $b} keys %seen_times_5;
        # print STDERR Dumper \@sorted_trait_names_5;

        my $trait_name_encoded_5 = 1;
        foreach my $trait_name (@sorted_trait_names_5) {
            if (!exists($trait_name_encoder_5{$trait_name})) {
                my $trait_name_e = 't'.$trait_name_encoded_5;
                $trait_name_encoder_5{$trait_name} = $trait_name_e;
                $trait_name_encoder_rev_5{$trait_name_e} = $trait_name;
                $trait_name_encoded_5++;
            }
        }

        foreach (@sorted_trait_names_5) {
            if ($_ < $time_min_5) {
                $time_min_5 = $_;
            }
            if ($_ >= $time_max_5) {
                $time_max_5 = $_;
            }
        }
        print STDERR Dumper [$time_min_5, $time_max_5];

        while ( my ($trait_name, $time_term) = each %seen_trait_names_5) {
            push @{$trait_composing_info_5{$trait_name}}, $time_term;
        }

        @phenotype_header_5 = ("id", "plot_id", "replicate", "rowNumber", "colNumber", "id_factor", "plot_id_factor");
        foreach (@sorted_trait_names) {
            push @phenotype_header_5, "t$_";
        }
        $header_string_5 = join ',', @phenotype_header_5;

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my $current_trait_index = 0;
            my @row = (
                $germplasm_stock_id,
                $obsunit_stock_id,
                $replicate,
                $row_number,
                $col_number,
                $accession_id_factor_map{$germplasm_stock_id},
                $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
            );

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_original_5{$p}->{$t})) {
                    push @row, $phenotype_data_original_5{$p}->{$t} + 0;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                }

                $current_trait_index++;
            }
            push @data_matrix_original_5, \@row;
        }

        open($F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            print $F $header_string_5."\n";
            foreach (@data_matrix_original_5) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);

        print STDERR "PREPARE RELATIONSHIP MATRIX\n";
        if ($statistics_select eq 'sommer_grm_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_temporal_random_regression_dap_genetic_blups' || $statistics_select eq 'sommer_grm_temporal_random_regression_gdd_genetic_blups' || $statistics_select eq 'sommer_grm_genetic_only_random_regression_dap_genetic_blups'
        || $statistics_select eq 'sommer_grm_genetic_only_random_regression_gdd_genetic_blups' || $statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups'
        || $statistics_select eq 'sommer_grm_genetic_blups' || $statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {

            my %seen_accession_stock_ids;
            foreach my $trial_id (@$field_trial_id_list) {
                my $trial = CXGN::Trial->new({ bcs_schema => $schema, trial_id => $trial_id });
                my $accessions = $trial->get_accessions();
                foreach (@$accessions) {
                    $seen_accession_stock_ids{$_->{stock_id}}++;
                }
            }
            my @accession_ids = keys %seen_accession_stock_ids;

            if ($compute_relationship_matrix_from_htp_phenotypes eq 'genotypes') {

                if ($include_pedgiree_info_if_compute_from_parents) {
                    my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
                    my $tmp_arm_dir = $shared_cluster_dir_config."/tmp_download_arm";
                    mkdir $tmp_arm_dir if ! -d $tmp_arm_dir;
                    my ($arm_tempfile_fh, $arm_tempfile) = tempfile("drone_stats_download_arm_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm1_tempfile_fh, $grm1_tempfile) = tempfile("drone_stats_download_grm1_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_temp_tempfile_fh, $grm_out_temp_tempfile) = tempfile("drone_stats_download_grm_temp_out_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_tempfile_fh, $grm_out_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_posdef_tempfile_fh, $grm_out_posdef_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);

                    if (!$protocol_id) {
                        $protocol_id = undef;
                    }

                    my $pedigree_arm = CXGN::Pedigree::ARM->new({
                        bcs_schema=>$schema,
                        arm_temp_file=>$arm_tempfile,
                        people_schema=>$people_schema,
                        accession_id_list=>\@accession_ids,
                        # plot_id_list=>\@plot_id_list,
                        cache_root=>$c->config->{cache_file_path},
                        download_format=>'matrix', #either 'matrix', 'three_column', or 'heatmap'
                    });
                    my ($parent_hash, $stock_ids, $all_accession_stock_ids, $female_stock_ids, $male_stock_ids) = $pedigree_arm->get_arm(
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    # print STDERR Dumper $parent_hash;

                    my $female_geno = CXGN::Genotype::GRM->new({
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm1_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>$female_stock_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>0,
                        download_format=>'three_column_reciprocal'
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    });
                    my $female_grm_data = $female_geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    my @fl = split '\n', $female_grm_data;
                    my %female_parent_grm;
                    foreach (@fl) {
                        my @l = split '\t', $_;
                        $female_parent_grm{$l[0]}->{$l[1]} = $l[2];
                    }
                    # print STDERR Dumper \%female_parent_grm;

                    my $male_geno = CXGN::Genotype::GRM->new({
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm1_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>$male_stock_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>0,
                        download_format=>'three_column_reciprocal'
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    });
                    my $male_grm_data = $male_geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    my @ml = split '\n', $male_grm_data;
                    my %male_parent_grm;
                    foreach (@ml) {
                        my @l = split '\t', $_;
                        $male_parent_grm{$l[0]}->{$l[1]} = $l[2];
                    }
                    # print STDERR Dumper \%male_parent_grm;

                    my %rel_result_hash;
                    foreach my $a1 (@accession_ids) {
                        foreach my $a2 (@accession_ids) {
                            my $female_parent1 = $parent_hash->{$a1}->{female_stock_id};
                            my $male_parent1 = $parent_hash->{$a1}->{male_stock_id};
                            my $female_parent2 = $parent_hash->{$a2}->{female_stock_id};
                            my $male_parent2 = $parent_hash->{$a2}->{male_stock_id};

                            my $female_rel = 0;
                            if ($female_parent1 && $female_parent2 && $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2}) {
                                $female_rel = $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2};
                            }
                            elsif ($female_parent1 && $female_parent2 && $female_parent1 == $female_parent2) {
                                $female_rel = 1;
                            }
                            elsif ($a1 == $a2) {
                                $female_rel = 1;
                            }

                            my $male_rel = 0;
                            if ($male_parent1 && $male_parent2 && $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2}) {
                                $male_rel = $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2};
                            }
                            elsif ($male_parent1 && $male_parent2 && $male_parent1 == $male_parent2) {
                                $male_rel = 1;
                            }
                            elsif ($a1 == $a2) {
                                $male_rel = 1;
                            }
                            # print STDERR "$a1 $a2 $female_rel $male_rel\n";

                            my $rel = 0.5*($female_rel + $male_rel);
                            $rel_result_hash{$a1}->{$a2} = $rel;
                        }
                    }
                    # print STDERR Dumper \%rel_result_hash;

                    my $data = '';
                    my %result_hash;
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $data .= "S$s\tS$c\t$val\n";
                                }
                            }
                        }
                    }

                    # print STDERR Dumper $data;
                    open(my $F2, ">", $grm_out_temp_tempfile) || die "Can't open file ".$grm_out_temp_tempfile;
                        print $F2 $data;
                    close($F2);

                    my $cmd = 'R -e "library(data.table); library(scales); library(tidyr); library(reshape2);
                    three_col <- fread(\''.$grm_out_temp_tempfile.'\', header=FALSE, sep=\'\t\');
                    A_wide <- dcast(three_col, V1~V2, value.var=\'V3\');
                    A_1 <- A_wide[,-1];
                    A_1[is.na(A_1)] <- 0;
                    A <- A_1 + t(A_1);
                    diag(A) <- diag(as.matrix(A_1));
                    E = eigen(A);
                    ev = E\$values;
                    U = E\$vectors;
                    no = dim(A)[1];
                    nev = which(ev < 0);
                    wr = 0;
                    k=length(nev);
                    if(k > 0){
                        p = ev[no - k];
                        B = sum(ev[nev])*2.0;
                        wr = (B*B*100.0)+1;
                        val = ev[nev];
                        ev[nev] = p*(B-val)*(B-val)/wr;
                        A = U%*%diag(ev)%*%t(U);
                    }
                    ';
                    if ($return_inverse_matrix) {
                        $cmd .= 'A <- solve(A);
                        ';
                    }
                    $cmd .= 'A <- as.data.frame(A);
                    colnames(A) <- A_wide[,1];
                    A\$stock_id <- A_wide[,1];
                    A_threecol <- melt(A, id.vars = c(\'stock_id\'), measure.vars = A_wide[,1]);
                    A_threecol\$stock_id <- substring(A_threecol\$stock_id, 2);
                    A_threecol\$variable <- substring(A_threecol\$variable, 2);
                    write.table(data.frame(variable = A_threecol\$variable, stock_id = A_threecol\$stock_id, value = A_threecol\$value), file=\''.$grm_out_tempfile.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');"';
                    print STDERR $cmd."\n";
                    my $status = system($cmd);

                    my %rel_pos_def_result_hash;
                    open(my $F3, '<', $grm_out_tempfile)
                        or die "Could not open file '$grm_out_tempfile' $!";

                        print STDERR "Opened $grm_out_tempfile\n";

                        while (my $row = <$F3>) {
                            my @columns;
                            if ($csv->parse($row)) {
                                @columns = $csv->fields();
                            }
                            my $stock_id1 = $columns[0];
                            my $stock_id2 = $columns[1];
                            my $val = $columns[2];
                            $rel_pos_def_result_hash{$stock_id1}->{$stock_id2} = $val;
                        }
                    close($F3);

                    my $data_pos_def = '';
                    if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
                        my %result_hash;
                        foreach my $s (sort @accession_ids) {
                            foreach my $c (sort @accession_ids) {
                                if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                    my $val = $rel_pos_def_result_hash{$s}->{$c};
                                    if (defined $val and length $val) {
                                        $result_hash{$s}->{$c} = $val;
                                        $data_pos_def .= "$s\t$c\t$val\n";
                                    }
                                }
                            }
                        }
                    }
                    else {
                        my %result_hash;
                        foreach my $s (sort @accession_ids) {
                            foreach my $c (sort @accession_ids) {
                                if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                    my $val = $rel_pos_def_result_hash{$s}->{$c};
                                    if (defined $val and length $val) {
                                        $result_hash{$s}->{$c} = $val;
                                        $result_hash{$c}->{$s} = $val;
                                        $data_pos_def .= "S$s\tS$c\t$val\n";
                                        if ($s != $c) {
                                            $data_pos_def .= "S$c\tS$s\t$val\n";
                                        }
                                    }
                                }
                            }
                        }
                    }

                    open(my $F4, ">", $grm_out_posdef_tempfile) || die "Can't open file ".$grm_out_posdef_tempfile;
                        print $F4 $data_pos_def;
                    close($F4);

                    $grm_file = $grm_out_posdef_tempfile;
                }
                elsif ($use_parental_grms_if_compute_from_parents) {
                    my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
                    my $tmp_arm_dir = $shared_cluster_dir_config."/tmp_download_arm";
                    mkdir $tmp_arm_dir if ! -d $tmp_arm_dir;
                    my ($arm_tempfile_fh, $arm_tempfile) = tempfile("drone_stats_download_arm_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm1_tempfile_fh, $grm1_tempfile) = tempfile("drone_stats_download_grm1_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_temp_tempfile_fh, $grm_out_temp_tempfile) = tempfile("drone_stats_download_grm_temp_out_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_tempfile_fh, $grm_out_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);
                    my ($grm_out_posdef_tempfile_fh, $grm_out_posdef_tempfile) = tempfile("drone_stats_download_grm_out_XXXXX", DIR=> $tmp_arm_dir);

                    if (!$protocol_id) {
                        $protocol_id = undef;
                    }

                    my $pedigree_arm = CXGN::Pedigree::ARM->new({
                        bcs_schema=>$schema,
                        arm_temp_file=>$arm_tempfile,
                        people_schema=>$people_schema,
                        accession_id_list=>\@accession_ids,
                        # plot_id_list=>\@plot_id_list,
                        cache_root=>$c->config->{cache_file_path},
                        download_format=>'matrix', #either 'matrix', 'three_column', or 'heatmap'
                    });
                    my ($parent_hash, $stock_ids, $all_accession_stock_ids, $female_stock_ids, $male_stock_ids) = $pedigree_arm->get_arm(
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    # print STDERR Dumper $parent_hash;

                    my $female_geno = CXGN::Genotype::GRM->new({
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm1_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>$female_stock_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>0,
                        download_format=>'three_column_reciprocal'
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    });
                    my $female_grm_data = $female_geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    my @fl = split '\n', $female_grm_data;
                    my %female_parent_grm;
                    foreach (@fl) {
                        my @l = split '\t', $_;
                        $female_parent_grm{$l[0]}->{$l[1]} = $l[2];
                    }
                    # print STDERR Dumper \%female_parent_grm;

                    my $male_geno = CXGN::Genotype::GRM->new({
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm1_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>$male_stock_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>0,
                        download_format=>'three_column_reciprocal'
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    });
                    my $male_grm_data = $male_geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );
                    my @ml = split '\n', $male_grm_data;
                    my %male_parent_grm;
                    foreach (@ml) {
                        my @l = split '\t', $_;
                        $male_parent_grm{$l[0]}->{$l[1]} = $l[2];
                    }
                    # print STDERR Dumper \%male_parent_grm;

                    my %rel_result_hash;
                    foreach my $a1 (@accession_ids) {
                        foreach my $a2 (@accession_ids) {
                            my $female_parent1 = $parent_hash->{$a1}->{female_stock_id};
                            my $male_parent1 = $parent_hash->{$a1}->{male_stock_id};
                            my $female_parent2 = $parent_hash->{$a2}->{female_stock_id};
                            my $male_parent2 = $parent_hash->{$a2}->{male_stock_id};

                            my $female_rel = 0;
                            if ($female_parent1 && $female_parent2 && $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2}) {
                                $female_rel = $female_parent_grm{'S'.$female_parent1}->{'S'.$female_parent2};
                            }
                            elsif ($a1 == $a2) {
                                $female_rel = 1;
                            }

                            my $male_rel = 0;
                            if ($male_parent1 && $male_parent2 && $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2}) {
                                $male_rel = $male_parent_grm{'S'.$male_parent1}->{'S'.$male_parent2};
                            }
                            elsif ($a1 == $a2) {
                                $male_rel = 1;
                            }
                            # print STDERR "$a1 $a2 $female_rel $male_rel\n";

                            my $rel = 0.5*($female_rel + $male_rel);
                            $rel_result_hash{$a1}->{$a2} = $rel;
                        }
                    }
                    # print STDERR Dumper \%rel_result_hash;

                    my $data = '';
                    my %result_hash;
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $data .= "S$s\tS$c\t$val\n";
                                }
                            }
                        }
                    }

                    # print STDERR Dumper $data;
                    open(my $F2, ">", $grm_out_temp_tempfile) || die "Can't open file ".$grm_out_temp_tempfile;
                        print $F2 $data;
                    close($F2);

                    my $cmd = 'R -e "library(data.table); library(scales); library(tidyr); library(reshape2);
                    three_col <- fread(\''.$grm_out_temp_tempfile.'\', header=FALSE, sep=\'\t\');
                    A_wide <- dcast(three_col, V1~V2, value.var=\'V3\');
                    A_1 <- A_wide[,-1];
                    A_1[is.na(A_1)] <- 0;
                    A <- A_1 + t(A_1);
                    diag(A) <- diag(as.matrix(A_1));
                    E = eigen(A);
                    ev = E\$values;
                    U = E\$vectors;
                    no = dim(A)[1];
                    nev = which(ev < 0);
                    wr = 0;
                    k=length(nev);
                    if(k > 0){
                        p = ev[no - k];
                        B = sum(ev[nev])*2.0;
                        wr = (B*B*100.0)+1;
                        val = ev[nev];
                        ev[nev] = p*(B-val)*(B-val)/wr;
                        A = U%*%diag(ev)%*%t(U);
                    }
                    ';
                    if ($return_inverse_matrix) {
                        $cmd .= 'A <- solve(A);
                        ';
                    }
                    $cmd .= 'A <- as.data.frame(A);
                    colnames(A) <- A_wide[,1];
                    A\$stock_id <- A_wide[,1];
                    A_threecol <- melt(A, id.vars = c(\'stock_id\'), measure.vars = A_wide[,1]);
                    A_threecol\$stock_id <- substring(A_threecol\$stock_id, 2);
                    A_threecol\$variable <- substring(A_threecol\$variable, 2);
                    write.table(data.frame(variable = A_threecol\$variable, stock_id = A_threecol\$stock_id, value = A_threecol\$value), file=\''.$grm_out_tempfile.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');"';
                    print STDERR $cmd."\n";
                    my $status = system($cmd);

                    my %rel_pos_def_result_hash;
                    open(my $F3, '<', $grm_out_tempfile)
                        or die "Could not open file '$grm_out_tempfile' $!";

                        print STDERR "Opened $grm_out_tempfile\n";

                        while (my $row = <$F3>) {
                            my @columns;
                            if ($csv->parse($row)) {
                                @columns = $csv->fields();
                            }
                            my $stock_id1 = $columns[0];
                            my $stock_id2 = $columns[1];
                            my $val = $columns[2];
                            $rel_pos_def_result_hash{$stock_id1}->{$stock_id2} = $val;
                        }
                    close($F3);

                    my $data_pos_def = '';
                    if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
                        my %result_hash;
                        foreach my $s (sort @accession_ids) {
                            foreach my $c (sort @accession_ids) {
                                if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                    my $val = $rel_pos_def_result_hash{$s}->{$c};
                                    if (defined $val and length $val) {
                                        $result_hash{$s}->{$c} = $val;
                                        $data_pos_def .= "$s\t$c\t$val\n";
                                    }
                                }
                            }
                        }
                    }
                    else {
                        my %result_hash;
                        foreach my $s (sort @accession_ids) {
                            foreach my $c (sort @accession_ids) {
                                if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                    my $val = $rel_pos_def_result_hash{$s}->{$c};
                                    if (defined $val and length $val) {
                                        $result_hash{$s}->{$c} = $val;
                                        $result_hash{$c}->{$s} = $val;
                                        $data_pos_def .= "S$s\tS$c\t$val\n";
                                        if ($s != $c) {
                                            $data_pos_def .= "S$c\tS$s\t$val\n";
                                        }
                                    }
                                }
                            }
                        }
                    }

                    open(my $F4, ">", $grm_out_posdef_tempfile) || die "Can't open file ".$grm_out_posdef_tempfile;
                        print $F4 $data_pos_def;
                    close($F4);

                    $grm_file = $grm_out_posdef_tempfile;
                }
                else {
                    my $shared_cluster_dir_config = $c->config->{cluster_shared_tempdir};
                    my $tmp_grm_dir = $shared_cluster_dir_config."/tmp_genotype_download_grm";
                    mkdir $tmp_grm_dir if ! -d $tmp_grm_dir;
                    my ($grm_tempfile_fh, $grm_tempfile) = tempfile("drone_stats_download_grm_XXXXX", DIR=> $tmp_grm_dir);
                    my ($grm_out_tempfile_fh, $grm_out_tempfile) = tempfile("drone_stats_download_grm_XXXXX", DIR=> $tmp_grm_dir);

                    if (!$protocol_id) {
                        $protocol_id = undef;
                    }

                    my $grm_search_params = {
                        bcs_schema=>$schema,
                        grm_temp_file=>$grm_tempfile,
                        people_schema=>$people_schema,
                        cache_root=>$c->config->{cache_file_path},
                        accession_id_list=>\@accession_ids,
                        protocol_id=>$protocol_id,
                        get_grm_for_parental_accessions=>$compute_from_parents,
                        return_inverse=>$return_inverse_matrix
                        # minor_allele_frequency=>$minor_allele_frequency,
                        # marker_filter=>$marker_filter,
                        # individuals_filter=>$individuals_filter
                    };

                    if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
                        $grm_search_params->{download_format} = 'three_column_stock_id_integer';
                    }
                    else {
                        $grm_search_params->{download_format} = 'three_column_reciprocal';
                    }

                    my $geno = CXGN::Genotype::GRM->new($grm_search_params);
                    my $grm_data = $geno->download_grm(
                        'data',
                        $shared_cluster_dir_config,
                        $c->config->{backend},
                        $c->config->{cluster_host},
                        $c->config->{'web_cluster_queue'},
                        $c->config->{basepath}
                    );

                    open(my $F2, ">", $grm_out_tempfile) || die "Can't open file ".$grm_out_tempfile;
                        print $F2 $grm_data;
                    close($F2);
                    $grm_file = $grm_out_tempfile;
                }

            }
            elsif ($compute_relationship_matrix_from_htp_phenotypes eq 'htp_phenotypes') {

                my $phenotypes_search = CXGN::Phenotypes::SearchFactory->instantiate(
                    'MaterializedViewTable',
                    {
                        bcs_schema=>$schema,
                        data_level=>'plot',
                        trial_list=>$field_trial_id_list,
                        include_timestamp=>0,
                        exclude_phenotype_outlier=>0
                    }
                );
                my ($data, $unique_traits) = $phenotypes_search->search();

                if (scalar(@$data) == 0) {
                    $c->stash->{rest} = { error => "There are no phenotypes for the trial you have selected!"};
                    return;
                }

                my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
                my $h_time = $schema->storage->dbh()->prepare($q_time);

                my %seen_plot_names_htp_rel;
                my %phenotype_data_htp_rel;
                my %seen_times_htp_rel;
                foreach my $obs_unit (@$data){
                    my $germplasm_name = $obs_unit->{germplasm_uniquename};
                    my $germplasm_stock_id = $obs_unit->{germplasm_stock_id};
                    my $row_number = $obs_unit->{obsunit_row_number} || '';
                    my $col_number = $obs_unit->{obsunit_col_number} || '';
                    my $rep = $obs_unit->{obsunit_rep};
                    my $block = $obs_unit->{obsunit_block};
                    $seen_plot_names_htp_rel{$obs_unit->{observationunit_uniquename}} = $obs_unit;
                    my $observations = $obs_unit->{observations};
                    foreach (@$observations){
                        if ($_->{associated_image_project_time_json}) {
                            my $related_time_terms_json = decode_json $_->{associated_image_project_time_json};

                            my $time_days_cvterm = $related_time_terms_json->{day};
                            my $time_days_term_string = $time_days_cvterm;
                            my $time_days = (split '\|', $time_days_cvterm)[0];
                            my $time_days_value = (split ' ', $time_days)[1];

                            my $time_gdd_value = $related_time_terms_json->{gdd_average_temp} + 0;
                            my $gdd_term_string = "GDD $time_gdd_value";
                            $h_time->execute($gdd_term_string, 'cxgn_time_ontology');
                            my ($gdd_cvterm_id) = $h_time->fetchrow_array();
                            if (!$gdd_cvterm_id) {
                                my $new_gdd_term = $schema->resultset("Cv::Cvterm")->create_with({
                                   name => $gdd_term_string,
                                   cv => 'cxgn_time_ontology'
                                });
                                $gdd_cvterm_id = $new_gdd_term->cvterm_id();
                            }
                            my $time_gdd_term_string = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $gdd_cvterm_id, 'extended');

                            $phenotype_data_htp_rel{$obs_unit->{observationunit_uniquename}}->{$_->{trait_name}} = $_->{value};
                            $seen_times_htp_rel{$_->{trait_name}} = [$time_days_value, $time_days_term_string, $time_gdd_value, $time_gdd_term_string];
                        }
                    }
                }

                my @allowed_standard_htp_values = ('Nonzero Pixel Count', 'Total Pixel Sum', 'Mean Pixel Value', 'Harmonic Mean Pixel Value', 'Median Pixel Value', 'Pixel Variance', 'Pixel Standard Deviation', 'Pixel Population Standard Deviation', 'Minimum Pixel Value', 'Maximum Pixel Value', 'Minority Pixel Value', 'Minority Pixel Count', 'Majority Pixel Value', 'Majority Pixel Count', 'Pixel Group Count');
                my %filtered_seen_times_htp_rel;
                while (my ($t, $time) = each %seen_times_htp_rel) {
                    my $allowed = 0;
                    foreach (@allowed_standard_htp_values) {
                        if (index($t, $_) != -1) {
                            $allowed = 1;
                            last;
                        }
                    }
                    if ($allowed) {
                        $filtered_seen_times_htp_rel{$t} = $time;
                    }
                }

                my @seen_plot_names_htp_rel_sorted = sort keys %seen_plot_names_htp_rel;
                my @filtered_seen_times_htp_rel_sorted = sort keys %filtered_seen_times_htp_rel;

                my @header_htp = ('plot_id', 'plot_name', 'accession_id', 'accession_name', 'rep', 'block');

                my %trait_name_encoder_htp;
                my %trait_name_encoder_rev_htp;
                my $trait_name_encoded_htp = 1;
                my @header_traits_htp;
                foreach my $trait_name (@filtered_seen_times_htp_rel_sorted) {
                    if (!exists($trait_name_encoder_htp{$trait_name})) {
                        my $trait_name_e = 't'.$trait_name_encoded_htp;
                        $trait_name_encoder_htp{$trait_name} = $trait_name_e;
                        $trait_name_encoder_rev_htp{$trait_name_e} = $trait_name;
                        push @header_traits_htp, $trait_name_e;
                        $trait_name_encoded_htp++;
                    }
                }

                my @htp_pheno_matrix;
                if ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'all') {
                    push @header_htp, @header_traits_htp;
                    push @htp_pheno_matrix, \@header_htp;

                    foreach my $p (@seen_plot_names_htp_rel_sorted) {
                        my $obj = $seen_plot_names_htp_rel{$p};
                        my @row = ($obj->{observationunit_stock_id}, $obj->{observationunit_uniquename}, $obj->{germplasm_stock_id}, $obj->{germplasm_uniquename}, $obj->{obsunit_rep}, $obj->{obsunit_block});
                        foreach my $t (@filtered_seen_times_htp_rel_sorted) {
                            my $val = $phenotype_data_htp_rel{$p}->{$t} + 0;
                            push @row, $val;
                        }
                        push @htp_pheno_matrix, \@row;
                    }
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'latest_trait') {
                    my $max_day = 0;
                    foreach (keys %seen_days_after_plantings) {
                        if ($_ + 0 > $max_day) {
                            $max_day = $_;
                        }
                    }

                    foreach my $t (@filtered_seen_times_htp_rel_sorted) {
                        my $day = $filtered_seen_times_htp_rel{$t}->[0];
                        if ($day <= $max_day) {
                            push @header_htp, $t;
                        }
                    }
                    push @htp_pheno_matrix, \@header_htp;

                    foreach my $p (@seen_plot_names_htp_rel_sorted) {
                        my $obj = $seen_plot_names_htp_rel{$p};
                        my @row = ($obj->{observationunit_stock_id}, $obj->{observationunit_uniquename}, $obj->{germplasm_stock_id}, $obj->{germplasm_uniquename}, $obj->{obsunit_rep}, $obj->{obsunit_block});
                        foreach my $t (@filtered_seen_times_htp_rel_sorted) {
                            my $day = $filtered_seen_times_htp_rel{$t}->[0];
                            if ($day <= $max_day) {
                                my $val = $phenotype_data_htp_rel{$p}->{$t} + 0;
                                push @row, $val;
                            }
                        }
                        push @htp_pheno_matrix, \@row;
                    }
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'vegetative') {
                    
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'reproductive') {
                    
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_time_points eq 'mature') {
                    
                }
                else {
                    $c->stash->{rest} = { error => "The value of $compute_relationship_matrix_from_htp_phenotypes_time_points htp_pheno_rel_matrix_time_points is not valid!" };
                    return;
                }

                open(my $htp_pheno_f, ">", $stats_out_htp_rel_tempfile_input) || die "Can't open file ".$stats_out_htp_rel_tempfile_input;
                    foreach (@htp_pheno_matrix) {
                        my $line = join "\t", @$_;
                        print $htp_pheno_f $line."\n";
                    }
                close($htp_pheno_f);

                my %rel_htp_result_hash;
                if ($compute_relationship_matrix_from_htp_phenotypes_type eq 'correlations') {
                    my $htp_cmd = 'R -e "library(lme4); library(data.table);
                    mat <- fread(\''.$stats_out_htp_rel_tempfile_input.'\', header=TRUE, sep=\'\t\');
                    mat_agg <- aggregate(mat[, 7:ncol(mat)], list(mat\$accession_id), mean);
                    mat_pheno <- mat_agg[,2:ncol(mat_agg)];
                    cor_mat <- cor(t(mat_pheno));
                    rownames(cor_mat) <- mat_agg[,1];
                    colnames(cor_mat) <- mat_agg[,1];
                    range01 <- function(x){(x-min(x))/(max(x)-min(x))};
                    cor_mat <- range01(cor_mat);
                    ';
                    if ($return_inverse_matrix) {
                        $htp_cmd .= 'cor_mat <- solve(cor_mat);
                        ';
                    }
                    $htp_cmd .= 'write.table(cor_mat, file=\''.$stats_out_htp_rel_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
                    print STDERR Dumper $htp_cmd;
                    my $status = system($htp_cmd);
                }
                elsif ($compute_relationship_matrix_from_htp_phenotypes_type eq 'blues') {
                    my $htp_cmd = 'R -e "library(lme4); library(data.table);
                    mat <- fread(\''.$stats_out_htp_rel_tempfile_input.'\', header=TRUE, sep=\'\t\');
                    blues <- data.frame(id = seq(1,length(unique(mat\$accession_id))));
                    varlist <- names(mat)[7:ncol(mat)];
                    blues.models <- lapply(varlist, function(x) {
                        tryCatch(
                            lmer(substitute(i ~ 1 + (1|accession_id), list(i = as.name(x))), data = mat, REML = FALSE, control = lmerControl(optimizer =\'Nelder_Mead\', boundary.tol='.$compute_relationship_matrix_from_htp_phenotypes_blues_inversion.' ) ), error=function(e) {}
                        )
                    });
                    counter = 1;
                    for (m in blues.models) {
                        if (!is.null(m)) {
                            blues\$accession_id <- row.names(ranef(m)\$accession_id);
                            blues[,ncol(blues) + 1] <- ranef(m)\$accession_id\$\`(Intercept)\`;
                            colnames(blues)[ncol(blues)] <- varlist[counter];
                        }
                        counter = counter + 1;
                    }
                    blues_vals <- as.matrix(blues[,3:ncol(blues)]);
                    blues_vals <- apply(blues_vals, 2, function(y) (y - mean(y)) / sd(y) ^ as.logical(sd(y)));
                    rel <- (1/ncol(blues_vals)) * (blues_vals %*% t(blues_vals));
                    ';
                    if ($return_inverse_matrix) {
                        $htp_cmd .= 'rel <- solve(rel);
                        ';
                    }
                    $htp_cmd .= 'rownames(rel) <- blues[,2];
                    colnames(rel) <- blues[,2];
                    write.table(rel, file=\''.$stats_out_htp_rel_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
                    print STDERR Dumper $htp_cmd;
                    my $status = system($htp_cmd);
                }
                else {
                    $c->stash->{rest} = { error => "The value of $compute_relationship_matrix_from_htp_phenotypes_type htp_pheno_rel_matrix_type is not valid!" };
                    return;
                }

                open(my $htp_rel_res, '<', $stats_out_htp_rel_tempfile)
                    or die "Could not open file '$stats_out_htp_rel_tempfile' $!";

                    print STDERR "Opened $stats_out_htp_rel_tempfile\n";
                    my $header_row = <$htp_rel_res>;
                    my @header;
                    if ($csv->parse($header_row)) {
                        @header = $csv->fields();
                    }

                    while (my $row = <$htp_rel_res>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $stock_id1 = $columns[0];
                        my $counter = 1;
                        foreach my $stock_id2 (@header) {
                            my $val = $columns[$counter];
                            $rel_htp_result_hash{$stock_id1}->{$stock_id2} = $val;
                            $counter++;
                        }
                    }
                close($htp_rel_res);

                my $data_rel_htp = '';
                my %result_hash;
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_htp_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $data_rel_htp .= "$s\t$c\t$val\n";
                                }
                            }
                        }
                    }
                }
                else {
                    foreach my $s (sort @accession_ids) {
                        foreach my $c (sort @accession_ids) {
                            if (!exists($result_hash{$s}->{$c}) && !exists($result_hash{$c}->{$s})) {
                                my $val = $rel_htp_result_hash{$s}->{$c};
                                if (defined $val and length $val) {
                                    $result_hash{$s}->{$c} = $val;
                                    $result_hash{$c}->{$s} = $val;
                                    $data_rel_htp .= "S$s\tS$c\t$val\n";
                                    if ($s != $c) {
                                        $data_rel_htp .= "S$c\tS$s\t$val\n";
                                    }
                                }
                            }
                        }
                    }
                }

                open(my $htp_rel_out, ">", $stats_out_htp_rel_tempfile_out) || die "Can't open file ".$stats_out_htp_rel_tempfile_out;
                    print $htp_rel_out $data_rel_htp;
                close($htp_rel_out);

                $grm_file = $stats_out_htp_rel_tempfile_out;
            }
            else {
                $c->stash->{rest} = { error => "The value of $compute_relationship_matrix_from_htp_phenotypes is not valid!" };
                return;
            }
        }
    };

    my ($statistical_ontology_term_5, $analysis_model_training_data_file_type_5, $analysis_model_language_5, $sorted_residual_trait_names_array_5, $rr_unique_traits_hash_5, $rr_residual_unique_traits_hash_5, $statistics_cmd_5, $cmd_f90_5, $number_traits_5, $trait_to_time_map_hash_5,
    $result_blup_data_original_5, $result_blup_data_delta_original_5, $result_blup_spatial_data_original_5, $result_blup_pe_data_original_5, $result_blup_pe_data_delta_original_5, $result_residual_data_original_5, $result_fitted_data_original_5, $fixed_effects_original_hash_5, $rr_genetic_coefficients_original_hash_5, $rr_temporal_coefficients_original_hash_5,
    $model_sum_square_residual_original_5, $genetic_effect_min_original_5, $genetic_effect_max_original_5, $env_effect_min_original_5, $env_effect_max_original_5, $genetic_effect_sum_square_original_5, $genetic_effect_sum_original_5, $env_effect_sum_square_original_5, $env_effect_sum_original_5, $residual_sum_square_original_5, $residual_sum_original_5,
    $phenotype_data_altered_hash_5, $data_matrix_altered_array_5, $data_matrix_phenotypes_altered_array_5, $phenotype_min_altered_5, $phenotype_max_altered_5,
    $result_blup_data_altered_1_5, $result_blup_data_delta_altered_1_5, $result_blup_spatial_data_altered_1_5, $result_blup_pe_data_altered_1_5, $result_blup_pe_data_delta_altered_1_5, $result_residual_data_altered_1_5, $result_fitted_data_altered_1_5, $fixed_effects_altered_hash_1_5, $rr_genetic_coefficients_altered_hash_1_5, $rr_temporal_coefficients_altered_hash_1_5,
    $model_sum_square_residual_altered_1_5, $genetic_effect_min_altered_1_5, $genetic_effect_max_altered_1_5, $env_effect_min_altered_1_5, $env_effect_max_altered_1_5, $genetic_effect_sum_square_altered_1_5, $genetic_effect_sum_altered_1_5, $env_effect_sum_square_altered_1_5, $env_effect_sum_altered_1_5, $residual_sum_square_altered_1_5, $residual_sum_altered_1_5,
    $phenotype_data_altered_env_hash_1_5, $data_matrix_altered_env_array_1_5, $data_matrix_phenotypes_altered_env_array_1_5, $phenotype_min_altered_env_1_5, $phenotype_max_altered_env_1_5, $env_sim_min_1_5, $env_sim_max_1_5, $sim_data_hash_1_5,
    $result_blup_data_altered_env_1_5, $result_blup_data_delta_altered_env_1_5, $result_blup_spatial_data_altered_env_1_5, $result_blup_pe_data_altered_env_1_5, $result_blup_pe_data_delta_altered_env_1_5, $result_residual_data_altered_env_1_5, $result_fitted_data_altered_env_1_5, $fixed_effects_altered_env_hash_1_5, $rr_genetic_coefficients_altered_env_hash_1_5, $rr_temporal_coefficients_altered_env_hash_1_5,
    $model_sum_square_residual_altered_env_1_5, $genetic_effect_min_altered_env_1_5, $genetic_effect_max_altered_env_1_5, $env_effect_min_altered_env_1_5, $env_effect_max_altered_env_1_5, $genetic_effect_sum_square_altered_env_1_5, $genetic_effect_sum_altered_env_1_5, $env_effect_sum_square_altered_env_1_5, $env_effect_sum_altered_env_1_5, $residual_sum_square_altered_env_1_5, $residual_sum_altered_env_1_5,
    $phenotype_data_altered_env_2_hash_5, $data_matrix_altered_env_2_array_5, $data_matrix_phenotypes_altered_env_2_array_5, $phenotype_min_altered_env_2_5, $phenotype_max_altered_env_2_5, $env_sim_min_2_5, $env_sim_max_2_5, $sim_data_2_hash_5,
    $result_blup_data_altered_env_2_5, $result_blup_data_delta_altered_env_2_5, $result_blup_spatial_data_altered_env_2_5, $result_blup_pe_data_altered_env_2_5, $result_blup_pe_data_delta_altered_env_2_5, $result_residual_data_altered_env_2_5, $result_fitted_data_altered_env_2_5, $fixed_effects_altered_env_2_hash_5, $rr_genetic_coefficients_altered_env_2_hash_5, $rr_temporal_coefficients_altered_env_2_hash_5,
    $model_sum_square_residual_altered_env_2_5, $genetic_effect_min_altered_env_2_5, $genetic_effect_max_altered_env_2_5, $env_effect_min_altered_env_2_5, $env_effect_max_altered_env_2_5, $genetic_effect_sum_square_altered_env_2_5, $genetic_effect_sum_altered_env_2_5, $env_effect_sum_square_altered_env_2_5, $env_effect_sum_altered_env_2_5, $residual_sum_square_altered_env_2_5, $residual_sum_altered_env_2_5,
    $phenotype_data_altered_env_3_hash_5, $data_matrix_altered_env_3_array_5, $data_matrix_phenotypes_altered_env_3_array_5, $phenotype_min_altered_env_3_5, $phenotype_max_altered_env_3_5, $env_sim_min_3_5, $env_sim_max_3_5, $sim_data_3_hash_5,
    $result_blup_data_altered_env_3_5, $result_blup_data_delta_altered_env_3_5, $result_blup_spatial_data_altered_env_3_5, $result_blup_pe_data_altered_env_3_5, $result_blup_pe_data_delta_altered_env_3_5, $result_residual_data_altered_env_3_5, $result_fitted_data_altered_env_3_5, $fixed_effects_altered_env_3_hash_5, $rr_genetic_coefficients_altered_env_3_hash_5, $rr_temporal_coefficients_altered_env_3_hash_5,
    $model_sum_square_residual_altered_env_3_5, $genetic_effect_min_altered_env_3_5, $genetic_effect_max_altered_env_3_5, $env_effect_min_altered_env_3_5, $env_effect_max_altered_env_3_5, $genetic_effect_sum_square_altered_env_3_5, $genetic_effect_sum_altered_env_3_5, $env_effect_sum_square_altered_env_3_5, $env_effect_sum_altered_env_3_5, $residual_sum_square_altered_env_3_5, $residual_sum_altered_env_3_5,
    $phenotype_data_altered_env_4_hash_5, $data_matrix_altered_env_4_array_5, $data_matrix_phenotypes_altered_env_4_array_5, $phenotype_min_altered_env_4_5, $phenotype_max_altered_env_4_5, $env_sim_min_4_5, $env_sim_max_4_5, $sim_data_4_hash_5,
    $result_blup_data_altered_env_4_5, $result_blup_data_delta_altered_env_4_5, $result_blup_spatial_data_altered_env_4_5, $result_blup_pe_data_altered_env_4_5, $result_blup_pe_data_delta_altered_env_4_5, $result_residual_data_altered_env_4_5, $result_fitted_data_altered_env_4_5, $fixed_effects_altered_env_4_hash_5, $rr_genetic_coefficients_altered_env_4_hash_5, $rr_temporal_coefficients_altered_env_4_hash_5,
    $model_sum_square_residual_altered_env_4_5, $genetic_effect_min_altered_env_4_5, $genetic_effect_max_altered_env_4_5, $env_effect_min_altered_env_4_5, $env_effect_max_altered_env_4_5, $genetic_effect_sum_square_altered_env_4_5, $genetic_effect_sum_altered_env_4_5, $env_effect_sum_square_altered_env_4_5, $env_effect_sum_altered_env_4_5, $residual_sum_square_altered_env_4_5, $residual_sum_altered_env_4_5,
    $phenotype_data_altered_env_5_hash_5, $data_matrix_altered_env_5_array_5, $data_matrix_phenotypes_altered_env_5_array_5, $phenotype_min_altered_env_5_5, $phenotype_max_altered_env_5_5, $env_sim_min_5_5, $env_sim_max_5_5, $sim_data_5_hash_5,
    $result_blup_data_altered_env_5_5, $result_blup_data_delta_altered_env_5_5, $result_blup_spatial_data_altered_env_5_5, $result_blup_pe_data_altered_env_5_5, $result_blup_pe_data_delta_altered_env_5_5, $result_residual_data_altered_env_5_5, $result_fitted_data_altered_env_5_5, $fixed_effects_altered_env_5_hash_5, $rr_genetic_coefficients_altered_env_5_hash_5, $rr_temporal_coefficients_altered_env_5_hash_5,
    $model_sum_square_residual_altered_env_5_5, $genetic_effect_min_altered_env_5_5, $genetic_effect_max_altered_env_5_5, $env_effect_min_altered_env_5_5, $env_effect_max_altered_env_5_5, $genetic_effect_sum_square_altered_env_5_5, $genetic_effect_sum_altered_env_5_5, $env_effect_sum_square_altered_env_5_5, $env_effect_sum_altered_env_5_5, $residual_sum_square_altered_env_5_5, $residual_sum_altered_env_5_5) = _perform_drone_imagery_analytics($c, $schema, $env_factor, $a_env, $b_env, $ro_env, $row_ro_env, $env_variance_percent, $protocol_id, $statistics_select, $analytics_select, $tolparinv, $use_area_under_curve, $env_simulation, $legendre_order_number, $permanent_environment_structure, \@legendre_coeff_exec, \%trait_name_encoder_5, \%trait_name_encoder_rev_5, \%stock_info_5, \%plot_id_map, \@sorted_trait_names_5, \%accession_id_factor_map, \@rep_time_factors, \@ind_rep_factors, \@unique_accession_names, \%plot_id_count_map_reverse, \@sorted_scaled_ln_times, \%time_count_map_reverse, \%accession_id_factor_map_reverse, \%seen_times, \%plot_id_factor_map_reverse, \%trait_to_time_map, \@unique_plot_names, \%stock_name_row_col, \%phenotype_data_original_5, \%plot_rep_time_factor_map, \%stock_row_col, \%stock_row_col_id, \%polynomial_map, \@plot_ids_ordered, $csv, $timestamp, $user_name, $stats_tempfile, $grm_file, $grm_rename_tempfile, $tmp_stats_dir, $stats_out_tempfile, $stats_out_tempfile_row, $stats_out_tempfile_col, $stats_out_tempfile_residual, $stats_out_tempfile_2dspl, $stats_prep2_tempfile, $stats_out_param_tempfile, $parameter_tempfile, $parameter_asreml_tempfile, $stats_tempfile_2, $permanent_environment_structure_tempfile, $permanent_environment_structure_env_tempfile, $permanent_environment_structure_env_tempfile2, $permanent_environment_structure_env_tempfile_mat, $yhat_residual_tempfile, $blupf90_solutions_tempfile, $coeff_genetic_tempfile, $coeff_pe_tempfile, $time_min, $time_max, $header_string_5, $env_sim_exec, $min_row, $max_row, $min_col, $max_col, $mean_row, $sig_row, $mean_col, $sig_col);
    %trait_to_time_map_5 = %$trait_to_time_map_hash_5;
    my @sorted_residual_trait_names_5 = @$sorted_residual_trait_names_array_5;
    my %rr_unique_traits_5 = %$rr_unique_traits_hash_5;
    my %rr_residual_unique_traits_5 = %$rr_residual_unique_traits_hash_5;
    my %fixed_effects_original_5 = %$fixed_effects_original_hash_5;
    my %rr_genetic_coefficients_original_5 = %$rr_genetic_coefficients_original_hash_5;
    my %rr_temporal_coefficients_original_5 = %$rr_temporal_coefficients_original_hash_5;
    my %phenotype_data_altered_5 = %$phenotype_data_altered_hash_5;
    my @data_matrix_altered_5 = @$data_matrix_altered_array_5;
    my @data_matrix_phenotypes_altered_5 = @$data_matrix_phenotypes_altered_array_5;
    my %fixed_effects_altered_1_5 = %$fixed_effects_altered_hash_1_5;
    my %rr_genetic_coefficients_altered_1_5 = %$rr_genetic_coefficients_altered_hash_1_5;
    my %rr_temporal_coefficients_altered_1_5 = %$rr_temporal_coefficients_altered_hash_1_5;
    my %phenotype_data_altered_env_1_5 = %$phenotype_data_altered_env_hash_1_5;
    my @data_matrix_altered_env_1_5 = @$data_matrix_altered_env_array_1_5;
    my @data_matrix_phenotypes_altered_env_1_5 = @$data_matrix_phenotypes_altered_env_array_1_5;
    my %sim_data_1_5 = %$sim_data_hash_1_5;
    my %fixed_effects_altered_env_1_5 = %$fixed_effects_altered_env_hash_1_5;
    my %rr_genetic_coefficients_altered_env_1_5 = %$rr_genetic_coefficients_altered_env_hash_1_5;
    my %rr_temporal_coefficients_altered_env_1_5 = %$rr_temporal_coefficients_altered_env_hash_1_5;
    my %phenotype_data_altered_env_2_5 = %$phenotype_data_altered_env_2_hash_5;
    my @data_matrix_altered_env_2_5 = @$data_matrix_altered_env_2_array_5;
    my @data_matrix_phenotypes_altered_env_2_5 = @$data_matrix_phenotypes_altered_env_2_array_5;
    my %sim_data_2_5 = %$sim_data_2_hash_5;
    my %fixed_effects_altered_env_2_5 = %$fixed_effects_altered_env_2_hash_5;
    my %rr_genetic_coefficients_altered_env_2_5 = %$rr_genetic_coefficients_altered_env_2_hash_5;
    my %rr_temporal_coefficients_altered_env_2_5 = %$rr_temporal_coefficients_altered_env_2_hash_5;
    my %phenotype_data_altered_env_3_5 = %$phenotype_data_altered_env_3_hash_5;
    my @data_matrix_altered_env_3_5 = @$data_matrix_altered_env_3_array_5;
    my @data_matrix_phenotypes_altered_env_3_5 = @$data_matrix_phenotypes_altered_env_3_array_5;
    my %sim_data_3_5 = %$sim_data_3_hash_5;
    my %fixed_effects_altered_env_3_5 = %$fixed_effects_altered_env_3_hash_5;
    my %rr_genetic_coefficients_altered_env_3_5 = %$rr_genetic_coefficients_altered_env_3_hash_5;
    my %rr_temporal_coefficients_altered_env_3_5 = %$rr_temporal_coefficients_altered_env_3_hash_5;
    my %phenotype_data_altered_env_4_5 = %$phenotype_data_altered_env_4_hash_5;
    my @data_matrix_altered_env_4_5 = @$data_matrix_altered_env_4_array_5;
    my @data_matrix_phenotypes_altered_env_4_5 = @$data_matrix_phenotypes_altered_env_4_array_5;
    my %sim_data_4_5 = %$sim_data_4_hash_5;
    my %fixed_effects_altered_env_4_5 = %$fixed_effects_altered_env_4_hash_5;
    my %rr_genetic_coefficients_altered_env_4_5 = %$rr_genetic_coefficients_altered_env_4_hash_5;
    my %rr_temporal_coefficients_altered_env_4_5 = %$rr_temporal_coefficients_altered_env_4_hash_5;
    my %phenotype_data_altered_env_5_5 = %$phenotype_data_altered_env_5_hash_5;
    my @data_matrix_altered_env_5_5 = @$data_matrix_altered_env_5_array_5;
    my @data_matrix_phenotypes_altered_env_5_5 = @$data_matrix_phenotypes_altered_env_5_array_5;
    my %sim_data_5_5 = %$sim_data_5_hash_5;
    my %fixed_effects_altered_env_5_5 = %$fixed_effects_altered_env_5_hash_5;
    my %rr_genetic_coefficients_altered_env_5_5 = %$rr_genetic_coefficients_altered_env_5_hash_5;
    my %rr_temporal_coefficients_altered_env_5_5 = %$rr_temporal_coefficients_altered_env_5_hash_5;

    my $spatial_effects_plots;
    my @env_corr_res;

    eval {
        print STDERR "PLOTTING CORRELATION\n";
        my ($full_plot_level_correlation_tempfile_fh, $full_plot_level_correlation_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open(my $F_fullplot, ">", $full_plot_level_correlation_tempfile) || die "Can't open file ".$full_plot_level_correlation_tempfile;
            print STDERR "OPENED PLOTCORR FILE $full_plot_level_correlation_tempfile\n";

            my @header_full_plot_corr;
            my @types_full_plot_corr = ('pheno_orig_', 'pheno_postm1_', 'pheno_postm2_', 'pheno_postm3_', 'pheno_postm4_', 'pheno_postm5_',
            'eff_origm1_', 'eff_origm2_', 'eff_origm3_', 'eff_origm4_', 'eff_origm5_', 'eff_postm1_', 'eff_postm2_', 'eff_postm3_', 'eff_postm4_', 'eff_postm5_',
            'sim_env1_', 'simm1_pheno1_', 'simm2_pheno1_', 'simm3_pheno1_', 'simm4_pheno1_', 'simm5_pheno1_', 'effm1_sim1_', 'effm2_sim1_', 'effm3_sim1_', 'effm4_sim1_', 'effm5_sim1_',
            'sim_env2_', 'simm1_pheno2_', 'simm2_pheno2_', 'simm3_pheno2_', 'simm4_pheno2_', 'simm5_pheno2_', 'effm1_sim2_', 'effm2_sim2_', 'effm3_sim2_', 'effm4_sim2_', 'effm5_sim2_',
            'sim_env3_', 'simm1_pheno3_', 'simm2_pheno3_', 'simm3_pheno3_', 'simm4_pheno3_', 'simm5_pheno3_', 'effm1_sim3_', 'effm2_sim3_', 'effm3_sim3_', 'effm4_sim3_', 'effm5_sim3_',
            'sim_env4_', 'simm1_pheno4_', 'simm2_pheno4_', 'simm3_pheno4_', 'simm4_pheno4_', 'simm5_pheno4_', 'effm1_sim4_', 'effm2_sim4_', 'effm3_sim4_', 'effm4_sim4_', 'effm5_sim4_',
            'sim_env5_', 'simm1_pheno5_', 'simm2_pheno5_', 'simm3_pheno5_', 'simm4_pheno5_', 'simm5_pheno5_', 'effm1_sim5_', 'effm2_sim5_', 'effm3_sim5_', 'effm4_sim5_', 'effm5_sim5_');
            foreach my $type (@types_full_plot_corr) {
                foreach my $t (@sorted_trait_names) {
                    push @header_full_plot_corr, $type.$trait_name_encoder{$t};
                }
            }
            my $header_string_full_plot_corr = join ',', @header_full_plot_corr;
            print $F_fullplot "$header_string_full_plot_corr\n";
            foreach my $p (@unique_plot_names) {
                my @row;
                foreach my $t (@sorted_trait_names) {
                    my $t_conv = $trait_name_encoder_rev_2{$trait_name_encoder{$t}};

                    my $phenotype_original = $phenotype_data_original{$p}->{$t};
                    my $phenotype_post_1 = $phenotype_data_altered{$p}->{$t};
                    my $phenotype_post_2 = $phenotype_data_altered_2{$p}->{$t_conv};
                    my $phenotype_post_3 = $phenotype_data_altered_3{$p}->{$t_conv};
                    my $phenotype_post_4 = $phenotype_data_altered_4{$p}->{$t};
                    my $phenotype_post_5 = $phenotype_data_altered_5{$p}->{$t};
                    my $effect_original_1 = $result_blup_pe_data_delta_original->{$p}->{$t}->[0];
                    my $effect_original_2 = $result_blup_spatial_data_original_2->{$p}->{$t_conv}->[0];
                    my $effect_original_3 = $result_blup_spatial_data_original_3->{$p}->{$t_conv}->[0];
                    my $effect_original_4 = $result_blup_pe_data_delta_original_4->{$p}->{$t}->[0];
                    my $effect_original_5 = $result_blup_spatial_data_original_5->{$p}->{$t}->[0];
                    my $effect_post_1 = $result_blup_pe_data_delta_altered->{$p}->{$t}->[0];
                    my $effect_post_2 = $result_blup_spatial_data_altered_1_2->{$p}->{$t_conv}->[0];
                    my $effect_post_3 = $result_blup_spatial_data_altered_1_3->{$p}->{$t_conv}->[0];
                    my $effect_post_4 = $result_blup_pe_data_delta_altered_1_4->{$p}->{$t}->[0];
                    my $effect_post_5 = $result_blup_spatial_data_altered_1_5->{$p}->{$t}->[0];
                    push @row, ($phenotype_original, $phenotype_post_1, $phenotype_post_2, $phenotype_post_3, $phenotype_post_4, $phenotype_post_5, $effect_original_1, $effect_original_2, $effect_original_3, $effect_original_4, $effect_original_5, $effect_post_1, $effect_post_2, $effect_post_3, $effect_post_4, $effect_post_5);

                    my $sim_env = $sim_data{$p}->{$t};
                    my $pheno_sim_1 = $phenotype_data_altered_env{$p}->{$t};
                    my $pheno_sim_2 = $phenotype_data_altered_env_1_2{$p}->{$t_conv};
                    my $pheno_sim_3 = $phenotype_data_altered_env_1_3{$p}->{$t_conv};
                    my $pheno_sim_4 = $phenotype_data_altered_env_1_4{$p}->{$t};
                    my $pheno_sim_5 = $phenotype_data_altered_env_1_5{$p}->{$t};
                    my $effect_sim_1 = $result_blup_pe_data_delta_altered_env->{$p}->{$t}->[0];
                    my $effect_sim_2 = $result_blup_spatial_data_altered_env_1_2->{$p}->{$t_conv}->[0];
                    my $effect_sim_3 = $result_blup_spatial_data_altered_env_1_3->{$p}->{$t_conv}->[0];
                    my $effect_sim_4 = $result_blup_pe_data_delta_altered_env_1_4->{$p}->{$t}->[0];
                    my $effect_sim_5 = $result_blup_spatial_data_altered_env_1_5->{$p}->{$t}->[0];
                    push @row, ($sim_env, $pheno_sim_1, $pheno_sim_2, $pheno_sim_3, $pheno_sim_4, $pheno_sim_5, $effect_sim_1, $effect_sim_2, $effect_sim_3, $effect_sim_4, $effect_sim_5);

                    my $sim_env2 = $sim_data_2{$p}->{$t};
                    my $pheno_sim2_1 = $phenotype_data_altered_env_2{$p}->{$t};
                    my $pheno_sim2_2 = $phenotype_data_altered_env_2_2{$p}->{$t_conv};
                    my $pheno_sim2_3 = $phenotype_data_altered_env_2_3{$p}->{$t_conv};
                    my $pheno_sim2_4 = $phenotype_data_altered_env_2_4{$p}->{$t};
                    my $pheno_sim2_5 = $phenotype_data_altered_env_2_5{$p}->{$t};
                    my $effect_sim2_1 = $result_blup_pe_data_delta_altered_env_2->{$p}->{$t}->[0];
                    my $effect_sim2_2 = $result_blup_spatial_data_altered_env_2_2->{$p}->{$t_conv}->[0];
                    my $effect_sim2_3 = $result_blup_spatial_data_altered_env_2_3->{$p}->{$t_conv}->[0];
                    my $effect_sim2_4 = $result_blup_pe_data_delta_altered_env_2_4->{$p}->{$t}->[0];
                    my $effect_sim2_5 = $result_blup_spatial_data_altered_env_2_5->{$p}->{$t}->[0];
                    push @row, ($sim_env2, $pheno_sim2_1, $pheno_sim2_2, $pheno_sim2_3, $pheno_sim2_4, $pheno_sim2_5, $effect_sim2_1, $effect_sim2_2, $effect_sim2_3, $effect_sim2_4, $effect_sim2_5);

                    my $sim_env3 = $sim_data_3{$p}->{$t};
                    my $pheno_sim3_1 = $phenotype_data_altered_env_3{$p}->{$t};
                    my $pheno_sim3_2 = $phenotype_data_altered_env_3_2{$p}->{$t_conv};
                    my $pheno_sim3_3 = $phenotype_data_altered_env_3_3{$p}->{$t_conv};
                    my $pheno_sim3_4 = $phenotype_data_altered_env_3_4{$p}->{$t};
                    my $pheno_sim3_5 = $phenotype_data_altered_env_3_5{$p}->{$t};
                    my $effect_sim3_1 = $result_blup_pe_data_delta_altered_env_3->{$p}->{$t}->[0];
                    my $effect_sim3_2 = $result_blup_spatial_data_altered_env_3_2->{$p}->{$t_conv}->[0];
                    my $effect_sim3_3 = $result_blup_spatial_data_altered_env_3_3->{$p}->{$t_conv}->[0];
                    my $effect_sim3_4 = $result_blup_pe_data_delta_altered_env_3_4->{$p}->{$t}->[0];
                    my $effect_sim3_5 = $result_blup_spatial_data_altered_env_3_5->{$p}->{$t}->[0];
                    push @row, ($sim_env3, $pheno_sim3_1, $pheno_sim3_2, $pheno_sim3_3, $pheno_sim3_4, $pheno_sim3_5, $effect_sim3_1, $effect_sim3_2, $effect_sim3_3, $effect_sim3_4, $effect_sim3_5);

                    my $sim_env4 = $sim_data_4{$p}->{$t};
                    my $pheno_sim4_1 = $phenotype_data_altered_env_4{$p}->{$t};
                    my $pheno_sim4_2 = $phenotype_data_altered_env_4_2{$p}->{$t_conv};
                    my $pheno_sim4_3 = $phenotype_data_altered_env_4_3{$p}->{$t_conv};
                    my $pheno_sim4_4 = $phenotype_data_altered_env_4_4{$p}->{$t};
                    my $pheno_sim4_5 = $phenotype_data_altered_env_4_5{$p}->{$t};
                    my $effect_sim4_1 = $result_blup_pe_data_delta_altered_env_4->{$p}->{$t}->[0];
                    my $effect_sim4_2 = $result_blup_spatial_data_altered_env_4_2->{$p}->{$t_conv}->[0];
                    my $effect_sim4_3 = $result_blup_spatial_data_altered_env_4_3->{$p}->{$t_conv}->[0];
                    my $effect_sim4_4 = $result_blup_pe_data_delta_altered_env_4_4->{$p}->{$t}->[0];
                    my $effect_sim4_5 = $result_blup_spatial_data_altered_env_4_5->{$p}->{$t}->[0];
                    push @row, ($sim_env4, $pheno_sim4_1, $pheno_sim4_2, $pheno_sim4_3, $pheno_sim4_4, $pheno_sim4_5, $effect_sim4_1, $effect_sim4_2, $effect_sim4_3, $effect_sim4_4, $effect_sim4_5);

                    my $sim_env5 = $sim_data_5{$p}->{$t};
                    my $pheno_sim5_1 = $phenotype_data_altered_env_5{$p}->{$t};
                    my $pheno_sim5_2 = $phenotype_data_altered_env_5_2{$p}->{$t_conv};
                    my $pheno_sim5_3 = $phenotype_data_altered_env_5_3{$p}->{$t_conv};
                    my $pheno_sim5_4 = $phenotype_data_altered_env_5_4{$p}->{$t};
                    my $pheno_sim5_5 = $phenotype_data_altered_env_5_5{$p}->{$t};
                    my $effect_sim5_1 = $result_blup_pe_data_delta_altered_env_5->{$p}->{$t}->[0];
                    my $effect_sim5_2 = $result_blup_spatial_data_altered_env_5_2->{$p}->{$t_conv}->[0];
                    my $effect_sim5_3 = $result_blup_spatial_data_altered_env_5_3->{$p}->{$t_conv}->[0];
                    my $effect_sim5_4 = $result_blup_pe_data_delta_altered_env_5_4->{$p}->{$t}->[0];
                    my $effect_sim5_5 = $result_blup_spatial_data_altered_env_5_5->{$p}->{$t}->[0];
                    push @row, ($sim_env5, $pheno_sim5_1, $pheno_sim5_2, $pheno_sim5_3, $pheno_sim5_4, $pheno_sim5_5, $effect_sim5_1, $effect_sim5_2, $effect_sim5_3, $effect_sim5_4, $effect_sim5_5);
                }
                my $line = join ',', @row;
                print $F_fullplot "$line\n";
            }
        close($F_fullplot);

        my $plot_corr_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $plot_corr_figure_tempfile_string .= '.png';
        my $plot_corr_figure_tempfile = $c->config->{basepath}."/".$plot_corr_figure_tempfile_string;

        my $cmd_plotcorr_plot = 'R -e "library(data.table); library(ggplot2); library(GGally);
        mat_orig <- fread(\''.$full_plot_level_correlation_tempfile.'\', header=TRUE, sep=\',\');
        gg <- ggcorr(data=mat_orig, hjust = 1, size = 2, color = \'grey50\', layout.exp = 1, label = TRUE);
        ggsave(\''.$plot_corr_figure_tempfile.'\', gg, device=\'png\', width=50, height=50, limitsize = FALSE, units=\'in\');
        "';
        # print STDERR Dumper $cmd;
        my $status_plotcorr_plot = system($cmd_plotcorr_plot);
        push @$spatial_effects_plots, $plot_corr_figure_tempfile_string;
    };

    eval {
        my @plot_corr_full_vals;
        
        my @original_pheno_vals;
        my ($phenotypes_original_heatmap_tempfile_fh, $phenotypes_original_heatmap_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open(my $F_pheno, ">", $phenotypes_original_heatmap_tempfile) || die "Can't open file ".$phenotypes_original_heatmap_tempfile;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_original{$p}->{$t};
                    my @row = ("pheno_orig_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    push @original_pheno_vals, $val;
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@original_pheno_vals;

        my $original_pheno_stat = Statistics::Descriptive::Full->new();
        $original_pheno_stat->add_data(@original_pheno_vals);
        my $sig_original_pheno = $original_pheno_stat->variance();

        #PHENO POST M START

        my @altered_pheno_vals;
        my ($phenotypes_post_heatmap_tempfile_fh, $phenotypes_post_heatmap_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_post_heatmap_tempfile) || die "Can't open file ".$phenotypes_post_heatmap_tempfile;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered{$p}->{$t};
                    my @row = ("pheno_postm1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    push @altered_pheno_vals, $val;
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@altered_pheno_vals;

        my $altered_pheno_stat = Statistics::Descriptive::Full->new();
        $altered_pheno_stat->add_data(@altered_pheno_vals);
        my $sig_altered_pheno = $altered_pheno_stat->variance();

        my @altered_pheno_vals_2;
        my ($phenotypes_post_heatmap_tempfile_fh_2, $phenotypes_post_heatmap_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_post_heatmap_tempfile_2) || die "Can't open file ".$phenotypes_post_heatmap_tempfile_2;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_2{$p}->{$t};
                    my @row = ("pheno_postm2_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    push @altered_pheno_vals_2, $val;
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@altered_pheno_vals_2;

        my $altered_pheno_stat_2 = Statistics::Descriptive::Full->new();
        $altered_pheno_stat_2->add_data(@altered_pheno_vals_2);
        my $sig_altered_pheno_2 = $altered_pheno_stat_2->variance();

        my @altered_pheno_vals_3;
        my ($phenotypes_post_heatmap_tempfile_fh_3, $phenotypes_post_heatmap_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_post_heatmap_tempfile_3) || die "Can't open file ".$phenotypes_post_heatmap_tempfile_3;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_3{$p}->{$t};
                    my @row = ("pheno_postm3_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    push @altered_pheno_vals_3, $val;
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@altered_pheno_vals_3;

        my $altered_pheno_stat_3 = Statistics::Descriptive::Full->new();
        $altered_pheno_stat_3->add_data(@altered_pheno_vals_3);
        my $sig_altered_pheno_3 = $altered_pheno_stat_3->variance();

        my @altered_pheno_vals_4;
        my ($phenotypes_post_heatmap_tempfile_fh_4, $phenotypes_post_heatmap_tempfile_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_post_heatmap_tempfile_4) || die "Can't open file ".$phenotypes_post_heatmap_tempfile_4;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_4{$p}->{$t};
                    my @row = ("pheno_postm4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    push @altered_pheno_vals_4, $val;
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@altered_pheno_vals_4;

        my $altered_pheno_stat_4 = Statistics::Descriptive::Full->new();
        $altered_pheno_stat_4->add_data(@altered_pheno_vals_4);
        my $sig_altered_pheno_4 = $altered_pheno_stat_4->variance();

        my @altered_pheno_vals_5;
        my ($phenotypes_post_heatmap_tempfile_fh_5, $phenotypes_post_heatmap_tempfile_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_post_heatmap_tempfile_5) || die "Can't open file ".$phenotypes_post_heatmap_tempfile_5;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_5{$p}->{$t};
                    my @row = ("pheno_postm5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    push @altered_pheno_vals_5, $val;
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@altered_pheno_vals_5;

        my $altered_pheno_stat_5 = Statistics::Descriptive::Full->new();
        $altered_pheno_stat_5->add_data(@altered_pheno_vals_5);
        my $sig_altered_pheno_5 = $altered_pheno_stat_5->variance();

        # EFFECT ORIGINAL M

        my @original_effect_vals;
        my ($effects_heatmap_tempfile_fh, $effects_heatmap_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open(my $F_eff, ">", $effects_heatmap_tempfile) || die "Can't open file ".$effects_heatmap_tempfile;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_original->{$p}->{$t}->[0];
                    my @row = ("eff_origm1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @original_effect_vals, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@original_effect_vals;

        my $original_effect_stat = Statistics::Descriptive::Full->new();
        $original_effect_stat->add_data(@original_effect_vals);
        my $sig_original_effect = $original_effect_stat->variance();

        my @original_effect_vals_2;
        my ($effects_heatmap_tempfile_fh_2, $effects_heatmap_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_heatmap_tempfile_2) || die "Can't open file ".$effects_heatmap_tempfile_2;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_original_2->{$p}->{$t}->[0];
                    my @row = ("eff_origm2_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @original_effect_vals_2, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@original_effect_vals_2;

        my $original_effect_stat_2 = Statistics::Descriptive::Full->new();
        $original_effect_stat_2->add_data(@original_effect_vals_2);
        my $sig_original_effect_2 = $original_effect_stat_2->variance();

        my @original_effect_vals_3;
        my ($effects_heatmap_tempfile_fh_3, $effects_heatmap_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_heatmap_tempfile_3) || die "Can't open file ".$effects_heatmap_tempfile_3;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_original_3->{$p}->{$t}->[0];
                    my @row = ("eff_origm3_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @original_effect_vals_3, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@original_effect_vals_3;

        my $original_effect_stat_3 = Statistics::Descriptive::Full->new();
        $original_effect_stat_3->add_data(@original_effect_vals_3);
        my $sig_original_effect_3 = $original_effect_stat_3->variance();

        my @original_effect_vals_4;
        my ($effects_heatmap_tempfile_fh_4, $effects_heatmap_tempfile_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_heatmap_tempfile_4) || die "Can't open file ".$effects_heatmap_tempfile_4;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_original_4->{$p}->{$t}->[0];
                    my @row = ("eff_origm4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @original_effect_vals_4, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@original_effect_vals_4;

        my $original_effect_stat_4 = Statistics::Descriptive::Full->new();
        $original_effect_stat_4->add_data(@original_effect_vals_4);
        my $sig_original_effect_4 = $original_effect_stat_4->variance();

        my @original_effect_vals_5;
        my ($effects_heatmap_tempfile_fh_5, $effects_heatmap_tempfile_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_heatmap_tempfile_5) || die "Can't open file ".$effects_heatmap_tempfile_5;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_spatial_data_original_5->{$p}->{$t}->[0];
                    my @row = ("eff_origm5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @original_effect_vals_5, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@original_effect_vals_5;

        my $original_effect_stat_5 = Statistics::Descriptive::Full->new();
        $original_effect_stat_5->add_data(@original_effect_vals_5);
        my $sig_original_effect_5 = $original_effect_stat_5->variance();

        # EFFECT POST M MIN

        my @altered_effect_vals;
        my ($effects_post_heatmap_tempfile_fh, $effects_post_heatmap_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_post_heatmap_tempfile) || die "Can't open file ".$effects_post_heatmap_tempfile;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered->{$p}->{$t}->[0];
                    my @row = ("eff_postm1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @altered_effect_vals, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@altered_effect_vals;

        my $altered_effect_stat = Statistics::Descriptive::Full->new();
        $altered_effect_stat->add_data(@altered_effect_vals);
        my $sig_altered_effect = $altered_effect_stat->variance();

        my @altered_effect_vals_2;
        my ($effects_post_heatmap_tempfile_fh_2, $effects_post_heatmap_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_post_heatmap_tempfile_2) || die "Can't open file ".$effects_post_heatmap_tempfile_2;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_1_2->{$p}->{$t}->[0];
                    my @row = ("eff_postm2_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @altered_effect_vals_2, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@altered_effect_vals_2;

        my $altered_effect_stat_2 = Statistics::Descriptive::Full->new();
        $altered_effect_stat_2->add_data(@altered_effect_vals_2);
        my $sig_altered_effect_2 = $altered_effect_stat_2->variance();

        my @altered_effect_vals_3;
        my ($effects_post_heatmap_tempfile_fh_3, $effects_post_heatmap_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_post_heatmap_tempfile_3) || die "Can't open file ".$effects_post_heatmap_tempfile_3;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_1_3->{$p}->{$t}->[0];
                    my @row = ("eff_postm3_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @altered_effect_vals_3, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@altered_effect_vals_3;

        my $altered_effect_stat_3 = Statistics::Descriptive::Full->new();
        $altered_effect_stat_3->add_data(@altered_effect_vals_3);
        my $sig_altered_effect_3 = $altered_effect_stat_3->variance();

        my @altered_effect_vals_4;
        my ($effects_post_heatmap_tempfile_fh_4, $effects_post_heatmap_tempfile_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_post_heatmap_tempfile_4) || die "Can't open file ".$effects_post_heatmap_tempfile_4;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_1_4->{$p}->{$t}->[0];
                    my @row = ("eff_postm4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @altered_effect_vals_4, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@altered_effect_vals_4;

        my $altered_effect_stat_4 = Statistics::Descriptive::Full->new();
        $altered_effect_stat_4->add_data(@altered_effect_vals_4);
        my $sig_altered_effect_4 = $altered_effect_stat_4->variance();

        my @altered_effect_vals_5;
        my ($effects_post_heatmap_tempfile_fh_5, $effects_post_heatmap_tempfile_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_post_heatmap_tempfile_5) || die "Can't open file ".$effects_post_heatmap_tempfile_5;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_spatial_data_altered_1_5->{$p}->{$t}->[0];
                    my @row = ("eff_postm5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @altered_effect_vals_5, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@altered_effect_vals_5;

        my $altered_effect_stat_5 = Statistics::Descriptive::Full->new();
        $altered_effect_stat_5->add_data(@altered_effect_vals_5);
        my $sig_altered_effect_5 = $altered_effect_stat_5->variance();

        # SIM ENV 1: ALTERED PHENO + EFFECT

        my ($phenotypes_env_heatmap_tempfile_fh, $phenotypes_env_heatmap_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_env_heatmap_tempfile) || die "Can't open file ".$phenotypes_env_heatmap_tempfile;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my @row = ("sim_env1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $sim_data{$p}->{$t});
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);

        my @sim_pheno1_vals;
        my ($phenotypes_pheno_sim_heatmap_tempfile_fh, $phenotypes_pheno_sim_heatmap_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env{$p}->{$t};
                    my @row = ("simm1_pheno1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno1_vals, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno1_vals;

        my $sim_pheno1_stat = Statistics::Descriptive::Full->new();
        $sim_pheno1_stat->add_data(@sim_pheno1_vals);
        my $sig_sim_pheno1 = $sim_pheno1_stat->variance();

        my @sim_pheno1_vals_2;
        my ($phenotypes_pheno_sim_heatmap_tempfile_fh_2, $phenotypes_pheno_sim_heatmap_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile_2) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile_2;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_1_2{$p}->{$t};
                    my @row = ("simm2_pheno1_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno1_vals_2, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno1_vals_2;

        my $sim_pheno1_stat_2 = Statistics::Descriptive::Full->new();
        $sim_pheno1_stat_2->add_data(@sim_pheno1_vals_2);
        my $sig_sim2_pheno1 = $sim_pheno1_stat_2->variance();

        my @sim_pheno1_vals_3;
        my ($phenotypes_pheno_sim_heatmap_tempfile_fh_3, $phenotypes_pheno_sim_heatmap_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile_3) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile_3;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_1_3{$p}->{$t};
                    my @row = ("simm3_pheno1_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno1_vals_3, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno1_vals_3;

        my $sim_pheno1_stat_3 = Statistics::Descriptive::Full->new();
        $sim_pheno1_stat_3->add_data(@sim_pheno1_vals_3);
        my $sig_sim3_pheno1 = $sim_pheno1_stat_3->variance();

        my @sim_pheno1_vals_4;
        my ($phenotypes_pheno_sim_heatmap_tempfile_fh_4, $phenotypes_pheno_sim_heatmap_tempfile_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile_4) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile_4;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_1_4{$p}->{$t};
                    my @row = ("simm4_pheno1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno1_vals_4, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno1_vals_4;

        my $sim_pheno1_stat_4 = Statistics::Descriptive::Full->new();
        $sim_pheno1_stat_4->add_data(@sim_pheno1_vals_4);
        my $sig_sim4_pheno1 = $sim_pheno1_stat_4->variance();

        my @sim_pheno1_vals_5;
        my ($phenotypes_pheno_sim_heatmap_tempfile_fh_5, $phenotypes_pheno_sim_heatmap_tempfile_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile_5) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile_5;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_1_5{$p}->{$t};
                    my @row = ("simm5_pheno1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno1_vals_5, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno1_vals_5;

        my $sim_pheno1_stat_5 = Statistics::Descriptive::Full->new();
        $sim_pheno1_stat_5->add_data(@sim_pheno1_vals_5);
        my $sig_sim5_pheno1 = $sim_pheno1_stat_5->variance();

        my @sim_effect1_vals;
        my ($effects_sim_heatmap_tempfile_fh, $effects_sim_heatmap_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile) || die "Can't open file ".$effects_sim_heatmap_tempfile;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env->{$p}->{$t}->[0];
                    my @row = ("effm1_sim1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect1_vals, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect1_vals;

        my $sim_effect1_stat = Statistics::Descriptive::Full->new();
        $sim_effect1_stat->add_data(@sim_effect1_vals);
        my $sig_sim_effect1 = $sim_effect1_stat->variance();

        my @sim_effect1_vals_2;
        my ($effects_sim_heatmap_tempfile_fh_2, $effects_sim_heatmap_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile_2) || die "Can't open file ".$effects_sim_heatmap_tempfile_2;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_1_2->{$p}->{$t}->[0];
                    my @row = ("effm2_sim1_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect1_vals_2, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect1_vals_2;

        my $sim_effect1_stat_2 = Statistics::Descriptive::Full->new();
        $sim_effect1_stat_2->add_data(@sim_effect1_vals_2);
        my $sig_sim2_effect1 = $sim_effect1_stat_2->variance();

        my @sim_effect1_vals_3;
        my ($effects_sim_heatmap_tempfile_fh_3, $effects_sim_heatmap_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile_3) || die "Can't open file ".$effects_sim_heatmap_tempfile_3;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_1_3->{$p}->{$t}->[0];
                    my @row = ("effm3_sim1_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect1_vals_3, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect1_vals_3;

        my $sim_effect1_stat_3 = Statistics::Descriptive::Full->new();
        $sim_effect1_stat_3->add_data(@sim_effect1_vals_3);
        my $sig_sim3_effect1 = $sim_effect1_stat_3->variance();

        my @sim_effect1_vals_4;
        my ($effects_sim_heatmap_tempfile_fh_4, $effects_sim_heatmap_tempfile_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile_4) || die "Can't open file ".$effects_sim_heatmap_tempfile_4;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env_1_4->{$p}->{$t}->[0];
                    my @row = ("effm4_sim1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect1_vals_4, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect1_vals_4;

        my $sim_effect1_stat_4 = Statistics::Descriptive::Full->new();
        $sim_effect1_stat_4->add_data(@sim_effect1_vals_4);
        my $sig_sim4_effect1 = $sim_effect1_stat_4->variance();

        my @sim_effect1_vals_5;
        my ($effects_sim_heatmap_tempfile_fh_5, $effects_sim_heatmap_tempfile_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile_5) || die "Can't open file ".$effects_sim_heatmap_tempfile_5;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_spatial_data_altered_env_1_5->{$p}->{$t}->[0];
                    my @row = ("effm5_sim1_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect1_vals_5, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect1_vals_5;

        my $sim_effect1_stat_5 = Statistics::Descriptive::Full->new();
        $sim_effect1_stat_5->add_data(@sim_effect1_vals_5);
        my $sig_sim5_effect1 = $sim_effect1_stat_5->variance();

        # SIM ENV 2: ALTERED PHENO + EFFECT

        my ($phenotypes_env_heatmap_tempfile2_fh, $phenotypes_env_heatmap_tempfile2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_env_heatmap_tempfile2) || die "Can't open file ".$phenotypes_env_heatmap_tempfile2;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my @row = ("sim_env2_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $sim_data_2{$p}->{$t});
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);

        my @sim_pheno2_vals;
        my ($phenotypes_pheno_sim_heatmap_tempfile2_fh, $phenotypes_pheno_sim_heatmap_tempfile2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile2) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile2;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_2{$p}->{$t};
                    my @row = ("simm1_pheno2_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno2_vals, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno2_vals;

        my $sim_pheno2_stat = Statistics::Descriptive::Full->new();
        $sim_pheno2_stat->add_data(@sim_pheno2_vals);
        my $sig_sim_pheno2 = $sim_pheno2_stat->variance();

        my @sim_pheno2_vals_2;
        my ($phenotypes_pheno_sim_heatmap_tempfile2_fh_2, $phenotypes_pheno_sim_heatmap_tempfile2_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile2_2) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile2_2;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_2_2{$p}->{$t};
                    my @row = ("simm2_pheno2_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno2_vals_2, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno2_vals_2;

        my $sim_pheno2_stat_2 = Statistics::Descriptive::Full->new();
        $sim_pheno2_stat_2->add_data(@sim_pheno2_vals_2);
        my $sig_sim_pheno2_2 = $sim_pheno2_stat_2->variance();

        my @sim_pheno2_vals_3;
        my ($phenotypes_pheno_sim_heatmap_tempfile2_fh_3, $phenotypes_pheno_sim_heatmap_tempfile2_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile2_3) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile2_3;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_2_3{$p}->{$t};
                    my @row = ("simm3_pheno2_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno2_vals_3, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno2_vals_3;

        my $sim_pheno2_stat_3 = Statistics::Descriptive::Full->new();
        $sim_pheno2_stat_3->add_data(@sim_pheno2_vals_3);
        my $sig_sim_pheno2_3 = $sim_pheno2_stat_3->variance();

        my @sim_pheno2_vals_4;
        my ($phenotypes_pheno_sim_heatmap_tempfile2_fh_4, $phenotypes_pheno_sim_heatmap_tempfile2_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile2_4) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile2_4;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_2_4{$p}->{$t};
                    my @row = ("simm4_pheno2_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno2_vals_4, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno2_vals_4;

        my $sim_pheno2_stat_4 = Statistics::Descriptive::Full->new();
        $sim_pheno2_stat_4->add_data(@sim_pheno2_vals_4);
        my $sig_sim_pheno2_4 = $sim_pheno2_stat_4->variance();

        my @sim_pheno2_vals_5;
        my ($phenotypes_pheno_sim_heatmap_tempfile2_fh_5, $phenotypes_pheno_sim_heatmap_tempfile2_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile2_5) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile2_5;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_2_5{$p}->{$t};
                    my @row = ("simm5_pheno2_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno2_vals_5, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno2_vals_5;

        my $sim_pheno2_stat_5 = Statistics::Descriptive::Full->new();
        $sim_pheno2_stat_5->add_data(@sim_pheno2_vals_5);
        my $sig_sim_pheno2_5 = $sim_pheno2_stat_5->variance();

        my @sim_effect2_vals;
        my ($effects_sim_heatmap_tempfile2_fh, $effects_sim_heatmap_tempfile2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile2) || die "Can't open file ".$effects_sim_heatmap_tempfile2;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env_2->{$p}->{$t}->[0];
                    my @row = ("effm1_sim2_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect2_vals, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect2_vals;

        my @sim_effect2_vals_2;
        my ($effects_sim_heatmap_tempfile2_fh_2, $effects_sim_heatmap_tempfile2_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile2_2) || die "Can't open file ".$effects_sim_heatmap_tempfile2_2;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_2_2->{$p}->{$t}->[0];
                    my @row = ("effm2_sim2_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect2_vals_2, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect2_vals_2;

        my $sim_effect2_stat_2 = Statistics::Descriptive::Full->new();
        $sim_effect2_stat_2->add_data(@sim_effect2_vals_2);
        my $sig_sim_effect2_2 = $sim_effect2_stat_2->variance();

        my @sim_effect2_vals_3;
        my ($effects_sim_heatmap_tempfile2_fh_3, $effects_sim_heatmap_tempfile2_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile2_3) || die "Can't open file ".$effects_sim_heatmap_tempfile2_3;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_2_3->{$p}->{$t}->[0];
                    my @row = ("effm3_sim2_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect2_vals_3, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect2_vals_3;

        my $sim_effect2_stat_3 = Statistics::Descriptive::Full->new();
        $sim_effect2_stat_3->add_data(@sim_effect2_vals_3);
        my $sig_sim_effect2_3 = $sim_effect2_stat_3->variance();

        my @sim_effect2_vals_4;
        my ($effects_sim_heatmap_tempfile2_fh_4, $effects_sim_heatmap_tempfile2_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile2_4) || die "Can't open file ".$effects_sim_heatmap_tempfile2_4;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env_2_4->{$p}->{$t}->[0];
                    my @row = ("effm4_sim2_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect2_vals_4, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect2_vals_4;

        my $sim_effect2_stat_4 = Statistics::Descriptive::Full->new();
        $sim_effect2_stat_4->add_data(@sim_effect2_vals_4);
        my $sig_sim_effect2_4 = $sim_effect2_stat_4->variance();

        my @sim_effect2_vals_5;
        my ($effects_sim_heatmap_tempfile2_fh_5, $effects_sim_heatmap_tempfile2_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile2_5) || die "Can't open file ".$effects_sim_heatmap_tempfile2_5;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_spatial_data_altered_env_2_5->{$p}->{$t}->[0];
                    my @row = ("effm5_sim2_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect2_vals_5, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect2_vals_5;

        my $sim_effect2_stat_5 = Statistics::Descriptive::Full->new();
        $sim_effect2_stat_5->add_data(@sim_effect2_vals_5);
        my $sig_sim_effect2_5 = $sim_effect2_stat_5->variance();

        # SIM ENV 3: ALTERED PHENO + EFFECT

        my ($phenotypes_env_heatmap_tempfile3_fh, $phenotypes_env_heatmap_tempfile3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_env_heatmap_tempfile3) || die "Can't open file ".$phenotypes_env_heatmap_tempfile3;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my @row = ("sim_env3_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $sim_data_3{$p}->{$t});
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);

        my @sim_pheno3_vals;
        my ($phenotypes_pheno_sim_heatmap_tempfile3_fh, $phenotypes_pheno_sim_heatmap_tempfile3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile3) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile3;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_3{$p}->{$t};
                    my @row = ("simm1_pheno3_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno3_vals, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno3_vals;

        my $sim_pheno3_stat = Statistics::Descriptive::Full->new();
        $sim_pheno3_stat->add_data(@sim_pheno3_vals);
        my $sig_sim_pheno3 = $sim_pheno3_stat->variance();

        my @sim_pheno3_vals_2;
        my ($phenotypes_pheno_sim_heatmap_tempfile3_fh_2, $phenotypes_pheno_sim_heatmap_tempfile3_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile3_2) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile3_2;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_3_2{$p}->{$t};
                    my @row = ("simm2_pheno3_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno3_vals_2, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno3_vals_2;

        my $sim_pheno3_stat_2 = Statistics::Descriptive::Full->new();
        $sim_pheno3_stat_2->add_data(@sim_pheno3_vals_2);
        my $sig_sim_pheno3_2 = $sim_pheno3_stat_2->variance();

        my @sim_pheno3_vals_3;
        my ($phenotypes_pheno_sim_heatmap_tempfile3_fh_3, $phenotypes_pheno_sim_heatmap_tempfile3_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile3_3) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile3_3;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_3_3{$p}->{$t};
                    my @row = ("simm3_pheno3_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno3_vals_3, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno3_vals_3;

        my $sim_pheno3_stat_3 = Statistics::Descriptive::Full->new();
        $sim_pheno3_stat_3->add_data(@sim_pheno3_vals_3);
        my $sig_sim_pheno3_3 = $sim_pheno3_stat_3->variance();

        my @sim_pheno3_vals_4;
        my ($phenotypes_pheno_sim_heatmap_tempfile3_fh_4, $phenotypes_pheno_sim_heatmap_tempfile3_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile3_4) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile3_4;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_3_4{$p}->{$t};
                    my @row = ("simm4_pheno3_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno3_vals_4, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno3_vals_4;

        my $sim_pheno3_stat_4 = Statistics::Descriptive::Full->new();
        $sim_pheno3_stat_4->add_data(@sim_pheno3_vals_4);
        my $sig_sim_pheno3_4 = $sim_pheno3_stat_4->variance();

        my @sim_pheno3_vals_5;
        my ($phenotypes_pheno_sim_heatmap_tempfile3_fh_5, $phenotypes_pheno_sim_heatmap_tempfile3_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile3_5) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile3_5;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_3_5{$p}->{$t};
                    my @row = ("simm5_pheno3_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno3_vals_5, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno3_vals_5;

        my $sim_pheno3_stat_5 = Statistics::Descriptive::Full->new();
        $sim_pheno3_stat_5->add_data(@sim_pheno3_vals_5);
        my $sig_sim_pheno3_5 = $sim_pheno3_stat_5->variance();

        my @sim_effect3_vals;
        my ($effects_sim_heatmap_tempfile3_fh, $effects_sim_heatmap_tempfile3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile3) || die "Can't open file ".$effects_sim_heatmap_tempfile3;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env_3->{$p}->{$t}->[0];
                    my @row = ("effm1_sim3_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect3_vals, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect3_vals;

        my $sim_effect3_stat = Statistics::Descriptive::Full->new();
        $sim_effect3_stat->add_data(@sim_effect3_vals);
        my $sig_sim_effect3 = $sim_effect3_stat->variance();

        my @sim_effect3_vals_2;
        my ($effects_sim_heatmap_tempfile3_fh_2, $effects_sim_heatmap_tempfile3_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile3_2) || die "Can't open file ".$effects_sim_heatmap_tempfile3_2;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_3_2->{$p}->{$t}->[0];
                    my @row = ("effm2_sim3_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect3_vals_2, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect3_vals_2;

        my $sim_effect3_stat_2 = Statistics::Descriptive::Full->new();
        $sim_effect3_stat_2->add_data(@sim_effect3_vals_2);
        my $sig_sim_effect3_2 = $sim_effect3_stat_2->variance();

        my @sim_effect3_vals_3;
        my ($effects_sim_heatmap_tempfile3_fh_3, $effects_sim_heatmap_tempfile3_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile3_3) || die "Can't open file ".$effects_sim_heatmap_tempfile3_3;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_3_3->{$p}->{$t}->[0];
                    my @row = ("effm3_sim3_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect3_vals_3, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect3_vals_3;

        my $sim_effect3_stat_3 = Statistics::Descriptive::Full->new();
        $sim_effect3_stat_3->add_data(@sim_effect3_vals_3);
        my $sig_sim_effect3_3 = $sim_effect3_stat_3->variance();

        my @sim_effect3_vals_4;
        my ($effects_sim_heatmap_tempfile3_fh_4, $effects_sim_heatmap_tempfile3_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile3_4) || die "Can't open file ".$effects_sim_heatmap_tempfile3_4;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env_3_4->{$p}->{$t}->[0];
                    my @row = ("effm4_sim3_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect3_vals_4, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect3_vals_4;

        my $sim_effect3_stat_4 = Statistics::Descriptive::Full->new();
        $sim_effect3_stat_4->add_data(@sim_effect3_vals_4);
        my $sig_sim_effect3_4 = $sim_effect3_stat_4->variance();

        my @sim_effect3_vals_5;
        my ($effects_sim_heatmap_tempfile3_fh_5, $effects_sim_heatmap_tempfile3_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile3_5) || die "Can't open file ".$effects_sim_heatmap_tempfile3_5;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_spatial_data_altered_env_3_5->{$p}->{$t}->[0];
                    my @row = ("effm5_sim3_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect3_vals_5, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect3_vals_5;

        my $sim_effect3_stat_5 = Statistics::Descriptive::Full->new();
        $sim_effect3_stat_5->add_data(@sim_effect3_vals_5);
        my $sig_sim_effect3_5 = $sim_effect3_stat_5->variance();

        # SIM ENV 4: ALTERED PHENO + EFFECT

        my ($phenotypes_env_heatmap_tempfile4_fh, $phenotypes_env_heatmap_tempfile4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_env_heatmap_tempfile4) || die "Can't open file ".$phenotypes_env_heatmap_tempfile4;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my @row = ("sim_env4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $sim_data_4{$p}->{$t});
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);

        my @sim_pheno4_vals;
        my ($phenotypes_pheno_sim_heatmap_tempfile4_fh, $phenotypes_pheno_sim_heatmap_tempfile4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile4) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile4;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_4{$p}->{$t};
                    my @row = ("simm1_pheno4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno4_vals, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno4_vals;

        my $sim_pheno4_stat = Statistics::Descriptive::Full->new();
        $sim_pheno4_stat->add_data(@sim_pheno4_vals);
        my $sig_sim_pheno4 = $sim_pheno4_stat->variance();

        my @sim_pheno4_vals_2;
        my ($phenotypes_pheno_sim_heatmap_tempfile4_fh_2, $phenotypes_pheno_sim_heatmap_tempfile4_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile4_2) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile4_2;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_4_2{$p}->{$t};
                    my @row = ("simm2_pheno4_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno4_vals_2, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno4_vals_2;

        my $sim_pheno4_stat_2 = Statistics::Descriptive::Full->new();
        $sim_pheno4_stat_2->add_data(@sim_pheno4_vals_2);
        my $sig_sim_pheno4_2 = $sim_pheno4_stat_2->variance();

        my @sim_pheno4_vals_3;
        my ($phenotypes_pheno_sim_heatmap_tempfile4_fh_3, $phenotypes_pheno_sim_heatmap_tempfile4_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile4_3) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile4_3;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_4_3{$p}->{$t};
                    my @row = ("simm3_pheno4_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno4_vals_3, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno4_vals_3;

        my $sim_pheno4_stat_3 = Statistics::Descriptive::Full->new();
        $sim_pheno4_stat_3->add_data(@sim_pheno4_vals_3);
        my $sig_sim_pheno4_3 = $sim_pheno4_stat_3->variance();

        my @sim_pheno4_vals_4;
        my ($phenotypes_pheno_sim_heatmap_tempfile4_fh_4, $phenotypes_pheno_sim_heatmap_tempfile4_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile4_4) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile4_4;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_4_4{$p}->{$t};
                    my @row = ("simm4_pheno4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno4_vals_4, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno4_vals_4;

        my $sim_pheno4_stat_4 = Statistics::Descriptive::Full->new();
        $sim_pheno4_stat_4->add_data(@sim_pheno4_vals_4);
        my $sig_sim_pheno4_4 = $sim_pheno4_stat_4->variance();

        my @sim_pheno4_vals_5;
        my ($phenotypes_pheno_sim_heatmap_tempfile4_fh_5, $phenotypes_pheno_sim_heatmap_tempfile4_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile4_5) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile4_5;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_4_5{$p}->{$t};
                    my @row = ("simm5_pheno4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno4_vals_5, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno4_vals_5;

        my $sim_pheno4_stat_5 = Statistics::Descriptive::Full->new();
        $sim_pheno4_stat_5->add_data(@sim_pheno4_vals_5);
        my $sig_sim_pheno4_5 = $sim_pheno4_stat_5->variance();

        my @sim_effect4_vals;
        my ($effects_sim_heatmap_tempfile4_fh, $effects_sim_heatmap_tempfile4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile4) || die "Can't open file ".$effects_sim_heatmap_tempfile4;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env_4->{$p}->{$t}->[0];
                    my @row = ("effm1_sim4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect4_vals, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect4_vals;

        my $sim_effect4_stat = Statistics::Descriptive::Full->new();
        $sim_effect4_stat->add_data(@sim_effect4_vals);
        my $sig_sim_effect4 = $sim_effect4_stat->variance();

        my @sim_effect4_vals_2;
        my ($effects_sim_heatmap_tempfile4_fh_2, $effects_sim_heatmap_tempfile4_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile4_2) || die "Can't open file ".$effects_sim_heatmap_tempfile4_2;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_4_2->{$p}->{$t}->[0];
                    my @row = ("effm2_sim4_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect4_vals_2, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect4_vals_2;

        my $sim_effect4_stat_2 = Statistics::Descriptive::Full->new();
        $sim_effect4_stat_2->add_data(@sim_effect4_vals_2);
        my $sig_sim_effect4_2 = $sim_effect4_stat_2->variance();

        my @sim_effect4_vals_3;
        my ($effects_sim_heatmap_tempfile4_fh_3, $effects_sim_heatmap_tempfile4_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile4_3) || die "Can't open file ".$effects_sim_heatmap_tempfile4_3;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_4_3->{$p}->{$t}->[0];
                    my @row = ("effm3_sim4_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect4_vals_3, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect4_vals_3;

        my $sim_effect4_stat_3 = Statistics::Descriptive::Full->new();
        $sim_effect4_stat_3->add_data(@sim_effect4_vals_3);
        my $sig_sim_effect4_3 = $sim_effect4_stat_3->variance();

        my @sim_effect4_vals_4;
        my ($effects_sim_heatmap_tempfile4_fh_4, $effects_sim_heatmap_tempfile4_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile4_4) || die "Can't open file ".$effects_sim_heatmap_tempfile4_4;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env_4_4->{$p}->{$t}->[0];
                    my @row = ("effm4_sim4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect4_vals_4, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect4_vals_4;

        my $sim_effect4_stat_4 = Statistics::Descriptive::Full->new();
        $sim_effect4_stat_4->add_data(@sim_effect4_vals_4);
        my $sig_sim_effect4_4 = $sim_effect4_stat_4->variance();

        my @sim_effect4_vals_5;
        my ($effects_sim_heatmap_tempfile4_fh_5, $effects_sim_heatmap_tempfile4_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile4_5) || die "Can't open file ".$effects_sim_heatmap_tempfile4_5;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_spatial_data_altered_env_4_5->{$p}->{$t}->[0];
                    my @row = ("effm5_sim4_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect4_vals_5, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect4_vals_5;

        my $sim_effect4_stat_5 = Statistics::Descriptive::Full->new();
        $sim_effect4_stat_5->add_data(@sim_effect4_vals_5);
        my $sig_sim_effect4_5 = $sim_effect4_stat_5->variance();

        # SIM ENV 5: ALTERED PHENO + EFFECT

        my ($phenotypes_env_heatmap_tempfile5_fh, $phenotypes_env_heatmap_tempfile5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_env_heatmap_tempfile5) || die "Can't open file ".$phenotypes_env_heatmap_tempfile5;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my @row = ("sim_env5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $sim_data_5{$p}->{$t});
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);

        my @sim_pheno5_vals;
        my ($phenotypes_pheno_sim_heatmap_tempfile5_fh, $phenotypes_pheno_sim_heatmap_tempfile5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile5) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile5;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_5{$p}->{$t};
                    my @row = ("simm1_pheno5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno5_vals, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno5_vals;

        my $sim_pheno5_stat = Statistics::Descriptive::Full->new();
        $sim_pheno5_stat->add_data(@sim_pheno5_vals);
        my $sig_sim_pheno5 = $sim_pheno5_stat->variance();

        my @sim_pheno5_vals_2;
        my ($phenotypes_pheno_sim_heatmap_tempfile5_fh_2, $phenotypes_pheno_sim_heatmap_tempfile5_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile5_2) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile5_2;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_5_2{$p}->{$t};
                    my @row = ("simm2_pheno5_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno5_vals_2, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno5_vals_2;

        my $sim_pheno5_stat_2 = Statistics::Descriptive::Full->new();
        $sim_pheno5_stat_2->add_data(@sim_pheno5_vals_2);
        my $sig_sim_pheno5_2 = $sim_pheno5_stat_2->variance();

        my @sim_pheno5_vals_3;
        my ($phenotypes_pheno_sim_heatmap_tempfile5_fh_3, $phenotypes_pheno_sim_heatmap_tempfile5_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile5_3) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile5_3;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $phenotype_data_altered_env_5_3{$p}->{$t};
                    my @row = ("simm3_pheno5_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno5_vals_3, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno5_vals_3;

        my $sim_pheno5_stat_3 = Statistics::Descriptive::Full->new();
        $sim_pheno5_stat_3->add_data(@sim_pheno5_vals_3);
        my $sig_sim_pheno5_3 = $sim_pheno5_stat_3->variance();

        my @sim_pheno5_vals_4;
        my ($phenotypes_pheno_sim_heatmap_tempfile5_fh_4, $phenotypes_pheno_sim_heatmap_tempfile5_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile5_4) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile5_4;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_5_4{$p}->{$t};
                    my @row = ("simm4_pheno5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno5_vals_4, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno5_vals_4;

        my $sim_pheno5_stat_4 = Statistics::Descriptive::Full->new();
        $sim_pheno5_stat_4->add_data(@sim_pheno5_vals_4);
        my $sig_sim_pheno5_4 = $sim_pheno5_stat_4->variance();

        my @sim_pheno5_vals_5;
        my ($phenotypes_pheno_sim_heatmap_tempfile5_fh_5, $phenotypes_pheno_sim_heatmap_tempfile5_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $phenotypes_pheno_sim_heatmap_tempfile5_5) || die "Can't open file ".$phenotypes_pheno_sim_heatmap_tempfile5_5;
            print $F_pheno "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $phenotype_data_altered_env_5_5{$p}->{$t};
                    my @row = ("simm5_pheno5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim_pheno5_vals_5, $val;
                }
            }
        close($F_pheno);
        push @plot_corr_full_vals, \@sim_pheno5_vals_5;

        my $sim_pheno5_stat_5 = Statistics::Descriptive::Full->new();
        $sim_pheno5_stat_5->add_data(@sim_pheno5_vals_5);
        my $sig_sim_pheno5_5 = $sim_pheno5_stat_5->variance();

        my @sim_effect5_vals;
        my ($effects_sim_heatmap_tempfile5_fh, $effects_sim_heatmap_tempfile5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile5) || die "Can't open file ".$effects_sim_heatmap_tempfile5;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env_5->{$p}->{$t}->[0];
                    my @row = ("effm1_sim5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect5_vals, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect5_vals;

        my $sim_effect5_stat = Statistics::Descriptive::Full->new();
        $sim_effect5_stat->add_data(@sim_effect5_vals);
        my $sig_sim_effect5 = $sim_effect5_stat->variance();

        my @sim_effect5_vals_2;
        my ($effects_sim_heatmap_tempfile5_fh_2, $effects_sim_heatmap_tempfile5_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile5_2) || die "Can't open file ".$effects_sim_heatmap_tempfile5_2;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_5_2->{$p}->{$t}->[0];
                    my @row = ("effm2_sim5_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect5_vals_2, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect5_vals_2;

        my $sim_effect5_stat_2 = Statistics::Descriptive::Full->new();
        $sim_effect5_stat_2->add_data(@sim_effect5_vals_2);
        my $sig_sim_effect5_2 = $sim_effect5_stat_2->variance();

        my @sim_effect5_vals_3;
        my ($effects_sim_heatmap_tempfile5_fh_3, $effects_sim_heatmap_tempfile5_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile5_3) || die "Can't open file ".$effects_sim_heatmap_tempfile5_3;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_spatial_data_altered_env_5_3->{$p}->{$t}->[0];
                    my @row = ("effm3_sim5_".$trait_name_encoder_2{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect5_vals_3, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect5_vals_3;

        my $sim_effect5_stat_3 = Statistics::Descriptive::Full->new();
        $sim_effect5_stat_3->add_data(@sim_effect5_vals_3);
        my $sig_sim_effect5_3 = $sim_effect5_stat_3->variance();

        my @sim_effect5_vals_4;
        my ($effects_sim_heatmap_tempfile5_fh_4, $effects_sim_heatmap_tempfile5_4) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile5_4) || die "Can't open file ".$effects_sim_heatmap_tempfile5_4;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_pe_data_delta_altered_env_5_4->{$p}->{$t}->[0];
                    my @row = ("effm4_sim5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect5_vals_4, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect5_vals_4;

        my $sim_effect5_stat_4 = Statistics::Descriptive::Full->new();
        $sim_effect5_stat_4->add_data(@sim_effect5_vals_4);
        my $sig_sim_effect5_4 = $sim_effect5_stat_4->variance();

        my @sim_effect5_vals_5;
        my ($effects_sim_heatmap_tempfile5_fh_5, $effects_sim_heatmap_tempfile5_5) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_eff, ">", $effects_sim_heatmap_tempfile5_5) || die "Can't open file ".$effects_sim_heatmap_tempfile5_5;
            print $F_eff "trait_type,row,col,value\n";
            foreach my $p (@unique_plot_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_spatial_data_altered_env_5_5->{$p}->{$t}->[0];
                    my @row = ("effm5_sim5_".$trait_name_encoder{$t}, $stock_name_row_col{$p}->{row_number}, $stock_name_row_col{$p}->{col_number}, $val);
                    my $line = join ',', @row;
                    print $F_eff "$line\n";
                    push @sim_effect5_vals_5, $val;
                }
            }
        close($F_eff);
        push @plot_corr_full_vals, \@sim_effect5_vals_5;

        my $sim_effect5_stat_5 = Statistics::Descriptive::Full->new();
        $sim_effect5_stat_5->add_data(@sim_effect5_vals_5);
        my $sig_sim_effect5_5 = $sim_effect5_stat_5->variance();

        my $plot_corr_summary_figure_inputfile_tempfile = $c->config->{basepath}."/".$c->tempfile( TEMPLATE => 'tmp_drone_statistics/fileXXXX');
        open($F_eff, ">", $plot_corr_summary_figure_inputfile_tempfile) || die "Can't open file ".$plot_corr_summary_figure_inputfile_tempfile;
            foreach (@plot_corr_full_vals) {
                my $line = join ',', @$_;
                print $F_eff $line."\n";
            }
        close($F_eff);


        my $plot_corr_summary_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $plot_corr_summary_figure_tempfile_string .= '.png';
        my $plot_corr_summary_figure_tempfile = $c->config->{basepath}."/".$plot_corr_summary_figure_tempfile_string;

        my $cmd_plotcorrsum_plot = 'R -e "library(data.table); library(ggplot2); library(GGally);
        mat_full_t <- fread(\''.$plot_corr_summary_figure_inputfile_tempfile.'\', header=FALSE, sep=\',\');
        mat_full <- data.frame(t(mat_full_t));
        colnames(mat_full) <- c(\'mat_orig\', \'mat_altered_1\', \'mat_altered_2\', \'mat_altered_3\', \'mat_altered_4\', \'mat_altered_5\', \'mat_eff_1\', \'mat_eff_2\', \'mat_eff_3\', \'mat_eff_4\', \'mat_eff_5\', \'mat_eff_altered_1\', \'mat_eff_altered_2\', \'mat_eff_altered_3\', \'mat_eff_altered_4\', \'mat_eff_altered_5\',
        \'mat_p_sim1_1\', \'mat_p_sim1_2\', \'mat_p_sim1_3\', \'mat_p_sim1_4\', \'mat_p_sim1_5\', \'mat_eff_sim1_1\', \'mat_eff_sim1_2\', \'mat_eff_sim1_3\', \'mat_eff_sim1_4\', \'mat_eff_sim1_5\',
        \'mat_p_sim2_1\', \'mat_p_sim2_2\', \'mat_p_sim2_3\', \'mat_p_sim2_4\', \'mat_p_sim2_5\', \'mat_eff_sim2_1\', \'mat_eff_sim2_2\', \'mat_eff_sim2_3\', \'mat_eff_sim2_4\', \'mat_eff_sim2_5\',
        \'mat_p_sim3_1\', \'mat_p_sim3_2\', \'mat_p_sim3_3\', \'mat_p_sim3_4\', \'mat_p_sim3_5\', \'mat_eff_sim3_1\', \'mat_eff_sim3_2\', \'mat_eff_sim3_3\', \'mat_eff_sim3_4\', \'mat_eff_sim3_5\',
        \'mat_p_sim4_1\', \'mat_p_sim4_2\', \'mat_p_sim4_3\', \'mat_p_sim4_4\', \'mat_p_sim4_5\', \'mat_eff_sim4_1\', \'mat_eff_sim4_2\', \'mat_eff_sim4_3\', \'mat_eff_sim4_4\', \'mat_eff_sim4_5\',
        \'mat_p_sim5_1\', \'mat_p_sim5_2\', \'mat_p_sim5_3\', \'mat_p_sim5_4\', \'mat_p_sim5_5\', \'mat_eff_sim5_1\', \'mat_eff_sim5_2\', \'mat_eff_sim5_3\', \'mat_eff_sim5_4\', \'mat_eff_sim5_5\');
        mat_env <- fread(\''.$phenotypes_env_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_env2 <- fread(\''.$phenotypes_env_heatmap_tempfile2.'\', header=TRUE, sep=\',\');
        mat_env3 <- fread(\''.$phenotypes_env_heatmap_tempfile3.'\', header=TRUE, sep=\',\');
        mat_env4 <- fread(\''.$phenotypes_env_heatmap_tempfile4.'\', header=TRUE, sep=\',\');
        mat_env5 <- fread(\''.$phenotypes_env_heatmap_tempfile5.'\', header=TRUE, sep=\',\');
        mat <- data.frame(pheno_orig = mat_full\$mat_orig, pheno_altm1 = mat_full\$mat_altered_1, pheno_altm2 = mat_full\$mat_altered_2, pheno_altm3 = mat_full\$mat_altered_3, pheno_altm4 = mat_full\$mat_altered_4, pheno_altm5 = mat_full\$mat_altered_5, eff_origm1 = mat_full\$mat_eff_1, eff_origm2 = mat_full\$mat_eff_2, eff_origm3 = mat_full\$mat_eff_3, eff_origm4 = mat_full\$mat_eff_4, eff_origm5 = mat_full\$mat_eff_5, eff_altm1 = mat_full\$mat_eff_altered_1, eff_altm2 = mat_full\$mat_eff_altered_2, eff_altm3 = mat_full\$mat_eff_altered_3, eff_altm4 = mat_full\$mat_eff_altered_4, eff_altm5 = mat_full\$mat_eff_altered_5, env_lin = mat_env\$value, pheno_linm1 = mat_full\$mat_p_sim1_1, pheno_linm2 = mat_full\$mat_p_sim1_2, pheno_linm3 = mat_full\$mat_p_sim1_3, pheno_linm4 = mat_full\$mat_p_sim1_4, pheno_linm5 = mat_full\$mat_p_sim1_5, lin_effm1 = mat_full\$mat_eff_sim1_1, lin_effm2 = mat_full\$mat_eff_sim1_2, lin_effm3 = mat_full\$mat_eff_sim1_3, lin_effm4 = mat_full\$mat_eff_sim1_4, lin_effm5 = mat_full\$mat_eff_sim1_5, env_n1d = mat_env2\$value, pheno_n1dm1 = mat_full\$mat_p_sim2_1, pheno_n1dm2 = mat_full\$mat_p_sim2_2, pheno_n1dm3 = mat_full\$mat_p_sim2_3, pheno_n1dm4 = mat_full\$mat_p_sim2_4, pheno_n1dm5 = mat_full\$mat_p_sim2_5, n1d_effm1 = mat_full\$mat_eff_sim2_1, n1d_effm2 = mat_full\$mat_eff_sim2_2, n1d_effm3 = mat_full\$mat_eff_sim2_3, n1d_effm4 = mat_full\$mat_eff_sim2_4, n1d_effm5 = mat_full\$mat_eff_sim2_5, env_n2d = mat_env3\$value, pheno_n2dm1 = mat_full\$mat_p_sim3_1, pheno_n2dm2 = mat_full\$mat_p_sim3_2, pheno_n2dm3 = mat_full\$mat_p_sim3_3, pheno_n2dm4 = mat_full\$mat_p_sim3_4, pheno_n2dm5 = mat_full\$mat_p_sim3_5, n2d_effm1 = mat_full\$mat_eff_sim3_1, n2d_effm2 = mat_full\$mat_eff_sim3_2, n2d_effm3 = mat_full\$mat_eff_sim3_3, n2d_effm4 = mat_full\$mat_eff_sim3_4, n2d_effm5 = mat_full\$mat_eff_sim3_5, env_rand = mat_env4\$value, pheno_randm1 = mat_full\$mat_p_sim4_1, pheno_randm2 = mat_full\$mat_p_sim4_2, pheno_randm3 = mat_full\$mat_p_sim4_3, pheno_randm4 = mat_full\$mat_p_sim4_4, pheno_randm5 = mat_full\$mat_p_sim4_5, rand_effm1 = mat_full\$mat_eff_sim4_1, rand_effm2 = mat_full\$mat_eff_sim4_2, rand_effm3 = mat_full\$mat_eff_sim4_3, rand_effm4 = mat_full\$mat_eff_sim4_4, rand_effm5 = mat_full\$mat_eff_sim4_5, env_ar1 = mat_env5\$value, pheno_ar1m1 = mat_full\$mat_p_sim5_1, pheno_ar1m2 = mat_full\$mat_p_sim5_2, pheno_ar1m3 = mat_full\$mat_p_sim5_3, pheno_ar1m4 = mat_full\$mat_p_sim5_4, pheno_ar1m5 = mat_full\$mat_p_sim5_5, ar1_effm1 = mat_full\$mat_eff_sim5_1, ar1_effm2 = mat_full\$mat_eff_sim5_2, ar1_effm3 = mat_full\$mat_eff_sim5_3, ar1_effm4 = mat_full\$mat_eff_sim5_4, ar1_effm5 = mat_full\$mat_eff_sim5_5);
        gg <- ggcorr(data=mat, hjust = 1, size = 2, color = \'grey50\', layout.exp = 1, label = TRUE, label_round = 2);
        ggsave(\''.$plot_corr_summary_figure_tempfile.'\', gg, device=\'png\', width=40, height=40, units=\'in\');
        "';
        # print STDERR Dumper $cmd_plotcorrsum_plot;

        my $status_plotcorrsum_plot = system($cmd_plotcorrsum_plot);
        push @$spatial_effects_plots, $plot_corr_summary_figure_tempfile_string;

        my $env_effects_first_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $env_effects_first_figure_tempfile_string .= '.png';
        my $env_effects_first_figure_tempfile = $c->config->{basepath}."/".$env_effects_first_figure_tempfile_string;

        my $env_effects_first_figure_tempfile_string_2 = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $env_effects_first_figure_tempfile_string_2 .= '.png';
        my $env_effects_first_figure_tempfile_2 = $c->config->{basepath}."/".$env_effects_first_figure_tempfile_string_2;

        my $output_plot_row = 'row';
        my $output_plot_col = 'col';
        if ($max_col > $max_row) {
            $output_plot_row = 'col';
            $output_plot_col = 'row';
        }

        my $cmd_spatialfirst_plot_2 = 'R -e "library(data.table); library(ggplot2); library(dplyr); library(viridis); library(GGally); library(gridExtra);
        mat_orig <- fread(\''.$phenotypes_original_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_altered_1 <- fread(\''.$phenotypes_post_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_altered_2 <- fread(\''.$phenotypes_post_heatmap_tempfile_2.'\', header=TRUE, sep=\',\');
        mat_altered_3 <- fread(\''.$phenotypes_post_heatmap_tempfile_3.'\', header=TRUE, sep=\',\');
        mat_altered_4 <- fread(\''.$phenotypes_post_heatmap_tempfile_4.'\', header=TRUE, sep=\',\');
        mat_altered_5 <- fread(\''.$phenotypes_post_heatmap_tempfile_5.'\', header=TRUE, sep=\',\');
        pheno_mat <- rbind(mat_orig, mat_altered_1, mat_altered_2, mat_altered_3, mat_altered_4, mat_altered_5);
        options(device=\'png\');
        par();
        gg <- ggplot(pheno_mat, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        ggsave(\''.$env_effects_first_figure_tempfile_2.'\', gg, device=\'png\', width=20, height=20, units=\'in\');
        "';
        # print STDERR Dumper $cmd;
        my $status_spatialfirst_plot_2 = system($cmd_spatialfirst_plot_2);
        push @$spatial_effects_plots, $env_effects_first_figure_tempfile_string_2;

        my ($sim_effects_corr_results_fh, $sim_effects_corr_results) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);

        my $cmd_spatialfirst_plot = 'R -e "library(data.table); library(ggplot2); library(dplyr); library(viridis); library(GGally); library(gridExtra);
        mat_full_t <- fread(\''.$plot_corr_summary_figure_inputfile_tempfile.'\', header=FALSE, sep=\',\');
        mat_full <- data.frame(t(mat_full_t));
        colnames(mat_full) <- c(\'mat_orig\', \'mat_altered_1\', \'mat_altered_2\', \'mat_altered_3\', \'mat_altered_4\', \'mat_altered_5\', \'mat_eff_1\', \'mat_eff_2\', \'mat_eff_3\', \'mat_eff_4\', \'mat_eff_5\', \'mat_eff_altered_1\', \'mat_eff_altered_2\', \'mat_eff_altered_3\', \'mat_eff_altered_4\', \'mat_eff_altered_5\',
        \'mat_p_sim1_1\', \'mat_p_sim1_2\', \'mat_p_sim1_3\', \'mat_p_sim1_4\', \'mat_p_sim1_5\', \'mat_eff_sim1_1\', \'mat_eff_sim1_2\', \'mat_eff_sim1_3\', \'mat_eff_sim1_4\', \'mat_eff_sim1_5\',
        \'mat_p_sim2_1\', \'mat_p_sim2_2\', \'mat_p_sim2_3\', \'mat_p_sim2_4\', \'mat_p_sim2_5\', \'mat_eff_sim2_1\', \'mat_eff_sim2_2\', \'mat_eff_sim2_3\', \'mat_eff_sim2_4\', \'mat_eff_sim2_5\',
        \'mat_p_sim3_1\', \'mat_p_sim3_2\', \'mat_p_sim3_3\', \'mat_p_sim3_4\', \'mat_p_sim3_5\', \'mat_eff_sim3_1\', \'mat_eff_sim3_2\', \'mat_eff_sim3_3\', \'mat_eff_sim3_4\', \'mat_eff_sim3_5\',
        \'mat_p_sim4_1\', \'mat_p_sim4_2\', \'mat_p_sim4_3\', \'mat_p_sim4_4\', \'mat_p_sim4_5\', \'mat_eff_sim4_1\', \'mat_eff_sim4_2\', \'mat_eff_sim4_3\', \'mat_eff_sim4_4\', \'mat_eff_sim4_5\',
        \'mat_p_sim5_1\', \'mat_p_sim5_2\', \'mat_p_sim5_3\', \'mat_p_sim5_4\', \'mat_p_sim5_5\', \'mat_eff_sim5_1\', \'mat_eff_sim5_2\', \'mat_eff_sim5_3\', \'mat_eff_sim5_4\', \'mat_eff_sim5_5\');
        mat_eff_1 <- fread(\''.$effects_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_eff_2 <- fread(\''.$effects_heatmap_tempfile_2.'\', header=TRUE, sep=\',\');
        mat_eff_3 <- fread(\''.$effects_heatmap_tempfile_3.'\', header=TRUE, sep=\',\');
        mat_eff_4 <- fread(\''.$effects_heatmap_tempfile_4.'\', header=TRUE, sep=\',\');
        mat_eff_5 <- fread(\''.$effects_heatmap_tempfile_5.'\', header=TRUE, sep=\',\');
        mat_eff_altered_1 <- fread(\''.$effects_post_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_eff_altered_2 <- fread(\''.$effects_post_heatmap_tempfile_2.'\', header=TRUE, sep=\',\');
        mat_eff_altered_3 <- fread(\''.$effects_post_heatmap_tempfile_3.'\', header=TRUE, sep=\',\');
        mat_eff_altered_4 <- fread(\''.$effects_post_heatmap_tempfile_4.'\', header=TRUE, sep=\',\');
        mat_eff_altered_5 <- fread(\''.$effects_post_heatmap_tempfile_5.'\', header=TRUE, sep=\',\');
        effect_mat_1 <- rbind(mat_eff_1, mat_eff_altered_1);
        effect_mat_2 <- rbind(mat_eff_2, mat_eff_altered_2);
        effect_mat_3 <- rbind(mat_eff_3, mat_eff_altered_3);
        effect_mat_4 <- rbind(mat_eff_4, mat_eff_altered_4);
        effect_mat_5 <- rbind(mat_eff_5, mat_eff_altered_5);
        mat_env <- fread(\''.$phenotypes_env_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_env2 <- fread(\''.$phenotypes_env_heatmap_tempfile2.'\', header=TRUE, sep=\',\');
        mat_env3 <- fread(\''.$phenotypes_env_heatmap_tempfile3.'\', header=TRUE, sep=\',\');
        mat_env4 <- fread(\''.$phenotypes_env_heatmap_tempfile4.'\', header=TRUE, sep=\',\');
        mat_env5 <- fread(\''.$phenotypes_env_heatmap_tempfile5.'\', header=TRUE, sep=\',\');
        options(device=\'png\');
        par();
        gg_eff_1 <- ggplot(effect_mat_1, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_2 <- ggplot(effect_mat_2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_3 <- ggplot(effect_mat_3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_4 <- ggplot(effect_mat_4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_5 <- ggplot(effect_mat_5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        ggsave(\''.$env_effects_first_figure_tempfile.'\', arrangeGrob(gg_eff_1, gg_eff_2, gg_eff_3, gg_eff_4, gg_eff_5, nrow=5), device=\'png\', width=25, height=25, units=\'in\');
        write.table(data.frame(m1env1 = c(cor(mat_env\$value, mat_full\$mat_eff_sim1_1)), m1env2 = c(cor(mat_env2\$value, mat_full\$mat_eff_sim2_1)), m1env3 = c(cor(mat_env3\$value, mat_full\$mat_eff_sim3_1)), m1env4 = c(cor(mat_env4\$value, mat_full\$mat_eff_sim4_1)), m1env5 = c(cor(mat_env5\$value, mat_full\$mat_eff_sim5_1)), m2env1 = c(cor(mat_env\$value, mat_full\$mat_eff_sim1_2)), m2env2 = c(cor(mat_env2\$value, mat_full\$mat_eff_sim2_2)), m2env3 = c(cor(mat_env3\$value, mat_full\$mat_eff_sim3_2)), m2env4 = c(cor(mat_env4\$value, mat_full\$mat_eff_sim4_2)), m2env5 = c(cor(mat_env5\$value, mat_full\$mat_eff_sim5_2)), m3env1 = c(cor(mat_env\$value, mat_full\$mat_eff_sim1_3)), m3env2 = c(cor(mat_env2\$value, mat_full\$mat_eff_sim2_3)), m3env3 = c(cor(mat_env3\$value, mat_full\$mat_eff_sim3_3)), m3env4 = c(cor(mat_env4\$value, mat_full\$mat_eff_sim4_3)), m3env5 = c(cor(mat_env5\$value, mat_full\$mat_eff_sim5_3)), m4env1 = c(cor(mat_env\$value, mat_full\$mat_eff_sim1_4)), m4env2 = c(cor(mat_env2\$value, mat_full\$mat_eff_sim2_4)), m4env3 = c(cor(mat_env3\$value, mat_full\$mat_eff_sim3_4)), m4env4 = c(cor(mat_env4\$value, mat_full\$mat_eff_sim4_4)), m4env5 = c(cor(mat_env5\$value, mat_full\$mat_eff_sim5_4)), m5env1 = c(cor(mat_env\$value, mat_full\$mat_eff_sim1_5)), m5env2 = c(cor(mat_env2\$value, mat_full\$mat_eff_sim2_5)), m5env3 = c(cor(mat_env3\$value, mat_full\$mat_eff_sim3_5)), m5env4 = c(cor(mat_env4\$value, mat_full\$mat_eff_sim4_5)), m5env5 = c(cor(mat_env5\$value, mat_full\$mat_eff_sim5_5))), file=\''.$sim_effects_corr_results.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');
        "';
        # print STDERR Dumper $cmd;
        my $status_spatialfirst_plot = system($cmd_spatialfirst_plot);
        push @$spatial_effects_plots, $env_effects_first_figure_tempfile_string;

        open(my $fh_corr_result, '<', $sim_effects_corr_results) or die "Could not open file '$sim_effects_corr_results' $!";
            print STDERR "Opened $sim_effects_corr_results\n";

            while (my $row = <$fh_corr_result>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                @env_corr_res = @columns;
            }
        close($fh_corr_result);

        my $env_effects_sim_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $env_effects_sim_figure_tempfile_string .= '.png';
        my $env_effects_sim_figure_tempfile = $c->config->{basepath}."/".$env_effects_sim_figure_tempfile_string;

        my $cmd_spatialenvsim_plot = 'R -e "library(data.table); library(ggplot2); library(dplyr); library(viridis); library(GGally); library(gridExtra);
        mat_env <- fread(\''.$phenotypes_env_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_p_sim <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_eff_sim <- fread(\''.$effects_sim_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_env2 <- fread(\''.$phenotypes_env_heatmap_tempfile2.'\', header=TRUE, sep=\',\');
        mat_p_sim2 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile2.'\', header=TRUE, sep=\',\');
        mat_eff_sim2 <- fread(\''.$effects_sim_heatmap_tempfile2.'\', header=TRUE, sep=\',\');
        mat_env3 <- fread(\''.$phenotypes_env_heatmap_tempfile3.'\', header=TRUE, sep=\',\');
        mat_p_sim3 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile3.'\', header=TRUE, sep=\',\');
        mat_eff_sim3 <- fread(\''.$effects_sim_heatmap_tempfile3.'\', header=TRUE, sep=\',\');
        mat_env4 <- fread(\''.$phenotypes_env_heatmap_tempfile4.'\', header=TRUE, sep=\',\');
        mat_p_sim4 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile4.'\', header=TRUE, sep=\',\');
        mat_eff_sim4 <- fread(\''.$effects_sim_heatmap_tempfile4.'\', header=TRUE, sep=\',\');
        mat_env5 <- fread(\''.$phenotypes_env_heatmap_tempfile5.'\', header=TRUE, sep=\',\');
        mat_p_sim5 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile5.'\', header=TRUE, sep=\',\');
        mat_eff_sim5 <- fread(\''.$effects_sim_heatmap_tempfile5.'\', header=TRUE, sep=\',\');
        options(device=\'png\');
        par();
        gg_env <- ggplot(mat_env, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim <- ggplot(mat_p_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim <- ggplot(mat_eff_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env2 <- ggplot(mat_env2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim2 <- ggplot(mat_p_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim2 <- ggplot(mat_eff_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env3 <- ggplot(mat_env3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim3 <- ggplot(mat_p_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim3 <- ggplot(mat_eff_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env4 <- ggplot(mat_env4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim4 <- ggplot(mat_p_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim4 <- ggplot(mat_eff_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env5 <- ggplot(mat_env5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim5 <- ggplot(mat_p_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim5 <- ggplot(mat_eff_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        ggsave(\''.$env_effects_sim_figure_tempfile.'\', arrangeGrob(gg_env, gg_p_sim, gg_eff_sim, gg_env2, gg_p_sim2, gg_eff_sim2, gg_env3, gg_p_sim3, gg_eff_sim3, gg_env4, gg_p_sim4, gg_eff_sim4, gg_env5, gg_p_sim5, gg_eff_sim5, nrow=5), device=\'png\', width=35, height=35, units=\'in\');
        "';
        # print STDERR Dumper $cmd_spatialenvsim_plot;
        my $status_spatialenvsim_plot = system($cmd_spatialenvsim_plot);
        push @$spatial_effects_plots, $env_effects_sim_figure_tempfile_string;

        my $env_effects_sim_figure_tempfile_string_2 = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $env_effects_sim_figure_tempfile_string_2 .= '.png';
        my $env_effects_sim_figure_tempfile_2 = $c->config->{basepath}."/".$env_effects_sim_figure_tempfile_string_2;

        my $cmd_spatialenvsim_plot_2 = 'R -e "library(data.table); library(ggplot2); library(dplyr); library(viridis); library(GGally); library(gridExtra);
        mat_env <- fread(\''.$phenotypes_env_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_p_sim <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile_2.'\', header=TRUE, sep=\',\');
        mat_eff_sim <- fread(\''.$effects_sim_heatmap_tempfile_2.'\', header=TRUE, sep=\',\');
        mat_env2 <- fread(\''.$phenotypes_env_heatmap_tempfile2.'\', header=TRUE, sep=\',\');
        mat_p_sim2 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile2_2.'\', header=TRUE, sep=\',\');
        mat_eff_sim2 <- fread(\''.$effects_sim_heatmap_tempfile2_2.'\', header=TRUE, sep=\',\');
        mat_env3 <- fread(\''.$phenotypes_env_heatmap_tempfile3.'\', header=TRUE, sep=\',\');
        mat_p_sim3 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile3_2.'\', header=TRUE, sep=\',\');
        mat_eff_sim3 <- fread(\''.$effects_sim_heatmap_tempfile3_2.'\', header=TRUE, sep=\',\');
        mat_env4 <- fread(\''.$phenotypes_env_heatmap_tempfile4.'\', header=TRUE, sep=\',\');
        mat_p_sim4 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile4_2.'\', header=TRUE, sep=\',\');
        mat_eff_sim4 <- fread(\''.$effects_sim_heatmap_tempfile4_2.'\', header=TRUE, sep=\',\');
        mat_env5 <- fread(\''.$phenotypes_env_heatmap_tempfile5.'\', header=TRUE, sep=\',\');
        mat_p_sim5 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile5_2.'\', header=TRUE, sep=\',\');
        mat_eff_sim5 <- fread(\''.$effects_sim_heatmap_tempfile5_2.'\', header=TRUE, sep=\',\');
        options(device=\'png\');
        par();
        gg_env <- ggplot(mat_env, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim <- ggplot(mat_p_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim <- ggplot(mat_eff_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env2 <- ggplot(mat_env2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim2 <- ggplot(mat_p_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim2 <- ggplot(mat_eff_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env3 <- ggplot(mat_env3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim3 <- ggplot(mat_p_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim3 <- ggplot(mat_eff_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env4 <- ggplot(mat_env4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim4 <- ggplot(mat_p_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim4 <- ggplot(mat_eff_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env5 <- ggplot(mat_env5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim5 <- ggplot(mat_p_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim5 <- ggplot(mat_eff_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        ggsave(\''.$env_effects_sim_figure_tempfile_2.'\', arrangeGrob(gg_env, gg_p_sim, gg_eff_sim, gg_env2, gg_p_sim2, gg_eff_sim2, gg_env3, gg_p_sim3, gg_eff_sim3, gg_env4, gg_p_sim4, gg_eff_sim4, gg_env5, gg_p_sim5, gg_eff_sim5, nrow=5), device=\'png\', width=35, height=35, units=\'in\');
        "';
        # print STDERR Dumper $cmd;
        my $status_spatialenvsim_plot_2 = system($cmd_spatialenvsim_plot_2);
        push @$spatial_effects_plots, $env_effects_sim_figure_tempfile_string_2;

        my $env_effects_sim_figure_tempfile_string_3 = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $env_effects_sim_figure_tempfile_string_3 .= '.png';
        my $env_effects_sim_figure_tempfile_3 = $c->config->{basepath}."/".$env_effects_sim_figure_tempfile_string_3;

        my $cmd_spatialenvsim_plot_3 = 'R -e "library(data.table); library(ggplot2); library(dplyr); library(viridis); library(GGally); library(gridExtra);
        mat_env <- fread(\''.$phenotypes_env_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_p_sim <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile_3.'\', header=TRUE, sep=\',\');
        mat_eff_sim <- fread(\''.$effects_sim_heatmap_tempfile_3.'\', header=TRUE, sep=\',\');
        mat_env2 <- fread(\''.$phenotypes_env_heatmap_tempfile2.'\', header=TRUE, sep=\',\');
        mat_p_sim2 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile2_3.'\', header=TRUE, sep=\',\');
        mat_eff_sim2 <- fread(\''.$effects_sim_heatmap_tempfile2_3.'\', header=TRUE, sep=\',\');
        mat_env3 <- fread(\''.$phenotypes_env_heatmap_tempfile3.'\', header=TRUE, sep=\',\');
        mat_p_sim3 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile3_3.'\', header=TRUE, sep=\',\');
        mat_eff_sim3 <- fread(\''.$effects_sim_heatmap_tempfile3_3.'\', header=TRUE, sep=\',\');
        mat_env4 <- fread(\''.$phenotypes_env_heatmap_tempfile4.'\', header=TRUE, sep=\',\');
        mat_p_sim4 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile4_3.'\', header=TRUE, sep=\',\');
        mat_eff_sim4 <- fread(\''.$effects_sim_heatmap_tempfile4_3.'\', header=TRUE, sep=\',\');
        mat_env5 <- fread(\''.$phenotypes_env_heatmap_tempfile5.'\', header=TRUE, sep=\',\');
        mat_p_sim5 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile5_3.'\', header=TRUE, sep=\',\');
        mat_eff_sim5 <- fread(\''.$effects_sim_heatmap_tempfile5_3.'\', header=TRUE, sep=\',\');
        options(device=\'png\');
        par();
        gg_env <- ggplot(mat_env, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim <- ggplot(mat_p_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim <- ggplot(mat_eff_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env2 <- ggplot(mat_env2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim2 <- ggplot(mat_p_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim2 <- ggplot(mat_eff_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env3 <- ggplot(mat_env3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim3 <- ggplot(mat_p_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim3 <- ggplot(mat_eff_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env4 <- ggplot(mat_env4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim4 <- ggplot(mat_p_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim4 <- ggplot(mat_eff_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env5 <- ggplot(mat_env5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim5 <- ggplot(mat_p_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim5 <- ggplot(mat_eff_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        ggsave(\''.$env_effects_sim_figure_tempfile_3.'\', arrangeGrob(gg_env, gg_p_sim, gg_eff_sim, gg_env2, gg_p_sim2, gg_eff_sim2, gg_env3, gg_p_sim3, gg_eff_sim3, gg_env4, gg_p_sim4, gg_eff_sim4, gg_env5, gg_p_sim5, gg_eff_sim5, nrow=5), device=\'png\', width=35, height=35, units=\'in\');
        "';
        # print STDERR Dumper $cmd;
        my $status_spatialenvsim_plot_3 = system($cmd_spatialenvsim_plot_3);
        push @$spatial_effects_plots, $env_effects_sim_figure_tempfile_string_3;

        my $env_effects_sim_figure_tempfile_string_4 = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $env_effects_sim_figure_tempfile_string_4 .= '.png';
        my $env_effects_sim_figure_tempfile_4 = $c->config->{basepath}."/".$env_effects_sim_figure_tempfile_string_4;

        my $cmd_spatialenvsim_plot_4 = 'R -e "library(data.table); library(ggplot2); library(dplyr); library(viridis); library(GGally); library(gridExtra);
        mat_env <- fread(\''.$phenotypes_env_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_p_sim <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile_4.'\', header=TRUE, sep=\',\');
        mat_eff_sim <- fread(\''.$effects_sim_heatmap_tempfile_4.'\', header=TRUE, sep=\',\');
        mat_env2 <- fread(\''.$phenotypes_env_heatmap_tempfile2.'\', header=TRUE, sep=\',\');
        mat_p_sim2 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile2_4.'\', header=TRUE, sep=\',\');
        mat_eff_sim2 <- fread(\''.$effects_sim_heatmap_tempfile2_4.'\', header=TRUE, sep=\',\');
        mat_env3 <- fread(\''.$phenotypes_env_heatmap_tempfile3.'\', header=TRUE, sep=\',\');
        mat_p_sim3 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile3_4.'\', header=TRUE, sep=\',\');
        mat_eff_sim3 <- fread(\''.$effects_sim_heatmap_tempfile3_4.'\', header=TRUE, sep=\',\');
        mat_env4 <- fread(\''.$phenotypes_env_heatmap_tempfile4.'\', header=TRUE, sep=\',\');
        mat_p_sim4 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile4_4.'\', header=TRUE, sep=\',\');
        mat_eff_sim4 <- fread(\''.$effects_sim_heatmap_tempfile4_4.'\', header=TRUE, sep=\',\');
        mat_env5 <- fread(\''.$phenotypes_env_heatmap_tempfile5.'\', header=TRUE, sep=\',\');
        mat_p_sim5 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile5_4.'\', header=TRUE, sep=\',\');
        mat_eff_sim5 <- fread(\''.$effects_sim_heatmap_tempfile5_4.'\', header=TRUE, sep=\',\');
        options(device=\'png\');
        par();
        gg_env <- ggplot(mat_env, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim <- ggplot(mat_p_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim <- ggplot(mat_eff_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env2 <- ggplot(mat_env2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim2 <- ggplot(mat_p_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim2 <- ggplot(mat_eff_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env3 <- ggplot(mat_env3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim3 <- ggplot(mat_p_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim3 <- ggplot(mat_eff_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env4 <- ggplot(mat_env4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim4 <- ggplot(mat_p_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim4 <- ggplot(mat_eff_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env5 <- ggplot(mat_env5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim5 <- ggplot(mat_p_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim5 <- ggplot(mat_eff_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        ggsave(\''.$env_effects_sim_figure_tempfile_4.'\', arrangeGrob(gg_env, gg_p_sim, gg_eff_sim, gg_env2, gg_p_sim2, gg_eff_sim2, gg_env3, gg_p_sim3, gg_eff_sim3, gg_env4, gg_p_sim4, gg_eff_sim4, gg_env5, gg_p_sim5, gg_eff_sim5, nrow=5), device=\'png\', width=35, height=35, units=\'in\');
        "';
        # print STDERR Dumper $cmd;
        my $status_spatialenvsim_plot_4 = system($cmd_spatialenvsim_plot_4);
        push @$spatial_effects_plots, $env_effects_sim_figure_tempfile_string_4;
        
        my $env_effects_sim_figure_tempfile_string_5 = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $env_effects_sim_figure_tempfile_string_5 .= '.png';
        my $env_effects_sim_figure_tempfile_5 = $c->config->{basepath}."/".$env_effects_sim_figure_tempfile_string_5;

        my $cmd_spatialenvsim_plot_5 = 'R -e "library(data.table); library(ggplot2); library(dplyr); library(viridis); library(GGally); library(gridExtra);
        mat_env <- fread(\''.$phenotypes_env_heatmap_tempfile.'\', header=TRUE, sep=\',\');
        mat_p_sim <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile_5.'\', header=TRUE, sep=\',\');
        mat_eff_sim <- fread(\''.$effects_sim_heatmap_tempfile_5.'\', header=TRUE, sep=\',\');
        mat_env2 <- fread(\''.$phenotypes_env_heatmap_tempfile2.'\', header=TRUE, sep=\',\');
        mat_p_sim2 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile2_5.'\', header=TRUE, sep=\',\');
        mat_eff_sim2 <- fread(\''.$effects_sim_heatmap_tempfile2_5.'\', header=TRUE, sep=\',\');
        mat_env3 <- fread(\''.$phenotypes_env_heatmap_tempfile3.'\', header=TRUE, sep=\',\');
        mat_p_sim3 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile3_5.'\', header=TRUE, sep=\',\');
        mat_eff_sim3 <- fread(\''.$effects_sim_heatmap_tempfile3_5.'\', header=TRUE, sep=\',\');
        mat_env4 <- fread(\''.$phenotypes_env_heatmap_tempfile4.'\', header=TRUE, sep=\',\');
        mat_p_sim4 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile4_5.'\', header=TRUE, sep=\',\');
        mat_eff_sim4 <- fread(\''.$effects_sim_heatmap_tempfile4_5.'\', header=TRUE, sep=\',\');
        mat_env5 <- fread(\''.$phenotypes_env_heatmap_tempfile5.'\', header=TRUE, sep=\',\');
        mat_p_sim5 <- fread(\''.$phenotypes_pheno_sim_heatmap_tempfile5_5.'\', header=TRUE, sep=\',\');
        mat_eff_sim5 <- fread(\''.$effects_sim_heatmap_tempfile5_5.'\', header=TRUE, sep=\',\');
        options(device=\'png\');
        par();
        gg_env <- ggplot(mat_env, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim <- ggplot(mat_p_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim <- ggplot(mat_eff_sim, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env2 <- ggplot(mat_env2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim2 <- ggplot(mat_p_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim2 <- ggplot(mat_eff_sim2, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env3 <- ggplot(mat_env3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim3 <- ggplot(mat_p_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim3 <- ggplot(mat_eff_sim3, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env4 <- ggplot(mat_env4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim4 <- ggplot(mat_p_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim4 <- ggplot(mat_eff_sim4, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_env5 <- ggplot(mat_env5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_p_sim5 <- ggplot(mat_p_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        gg_eff_sim5 <- ggplot(mat_eff_sim5, aes('.$output_plot_col.', '.$output_plot_row.', fill=value)) +
            geom_tile() +
            scale_fill_viridis(discrete=FALSE) +
            coord_equal() +
            facet_wrap(~trait_type, ncol='.scalar(@sorted_trait_names).');
        ggsave(\''.$env_effects_sim_figure_tempfile_5.'\', arrangeGrob(gg_env, gg_p_sim, gg_eff_sim, gg_env2, gg_p_sim2, gg_eff_sim2, gg_env3, gg_p_sim3, gg_eff_sim3, gg_env4, gg_p_sim4, gg_eff_sim4, gg_env5, gg_p_sim5, gg_eff_sim5, nrow=5), device=\'png\', width=35, height=35, units=\'in\');
        "';
        # print STDERR Dumper $cmd_spatialenvsim_plot_5;
        my $status_spatialenvsim_plot_5 = system($cmd_spatialenvsim_plot_5);
        push @$spatial_effects_plots, $env_effects_sim_figure_tempfile_string_5;
    };

    eval {
        my @sorted_germplasm_names = sort keys %unique_accessions;
        @sorted_trait_names = sort keys %rr_unique_traits;
        @sorted_residual_trait_names = sort keys %rr_residual_unique_traits;

        my @original_blup_vals;
        my ($effects_original_line_chart_tempfile_fh, $effects_original_line_chart_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open(my $F_pheno, ">", $effects_original_line_chart_tempfile) || die "Can't open file ".$effects_original_line_chart_tempfile;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_data_original->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map{$t}, $val);
                    push @original_blup_vals, $val;
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);

        my $original_blup_stat = Statistics::Descriptive::Full->new();
        $original_blup_stat->add_data(@original_blup_vals);
        my $sig_original_blup = $original_blup_stat->variance();

        my @original_blup_vals_2;
        my ($effects_original_line_chart_tempfile_fh_2, $effects_original_line_chart_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_original_line_chart_tempfile_2) || die "Can't open file ".$effects_original_line_chart_tempfile_2;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_original_2->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    push @original_blup_vals_2, $val;
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);

        my $original_blup_stat_2 = Statistics::Descriptive::Full->new();
        $original_blup_stat_2->add_data(@original_blup_vals_2);
        my $sig_original_blup_2 = $original_blup_stat_2->variance();

        my @original_blup_vals_3;
        my ($effects_original_line_chart_tempfile_fh_3, $effects_original_line_chart_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_original_line_chart_tempfile_3) || die "Can't open file ".$effects_original_line_chart_tempfile_3;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_original_3->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    push @original_blup_vals_3, $val;
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                }
            }
        close($F_pheno);

        my $original_blup_stat_3 = Statistics::Descriptive::Full->new();
        $original_blup_stat_3->add_data(@original_blup_vals_3);
        my $sig_original_blup_3 = $original_blup_stat_3->variance();

        my @altered_blups_vals;
        my ($effects_altered_line_chart_tempfile_fh, $effects_altered_line_chart_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_line_chart_tempfile) || die "Can't open file ".$effects_altered_line_chart_tempfile;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_data_altered->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @altered_blups_vals, $val;
                }
            }
        close($F_pheno);

        my $altered_blup_stat = Statistics::Descriptive::Full->new();
        $altered_blup_stat->add_data(@altered_blups_vals);
        my $sig_altered_blup = $altered_blup_stat->variance();

        my @altered_blups_vals_2;
        my ($effects_altered_line_chart_tempfile_fh_2, $effects_altered_line_chart_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_line_chart_tempfile_2) || die "Can't open file ".$effects_altered_line_chart_tempfile_2;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_altered_1_2->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @altered_blups_vals_2, $val;
                }
            }
        close($F_pheno);

        my $altered_blup_stat_2 = Statistics::Descriptive::Full->new();
        $altered_blup_stat_2->add_data(@altered_blups_vals_2);
        my $sig_altered_blup_2 = $altered_blup_stat_2->variance();

        my @altered_blups_vals_3;
        my ($effects_altered_line_chart_tempfile_fh_3, $effects_altered_line_chart_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_line_chart_tempfile_3) || die "Can't open file ".$effects_altered_line_chart_tempfile_3;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_altered_1_3->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @altered_blups_vals_3, $val;
                }
            }
        close($F_pheno);

        my $altered_blup_stat_3 = Statistics::Descriptive::Full->new();
        $altered_blup_stat_3->add_data(@altered_blups_vals_3);
        my $sig_altered_blup_3 = $altered_blup_stat_3->variance();

        my @sim1_blup_vals;
        my ($effects_altered_env1_line_chart_tempfile_fh, $effects_altered_env1_line_chart_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env1_line_chart_tempfile) || die "Can't open file ".$effects_altered_env1_line_chart_tempfile;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_data_altered_env->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim1_blup_vals, $val;
                }
            }
        close($F_pheno);

        my $sim1_blup_stat = Statistics::Descriptive::Full->new();
        $sim1_blup_stat->add_data(@sim1_blup_vals);
        my $sig_sim1_blup = $sim1_blup_stat->variance();

        my @sim1_blup_vals_2;
        my ($effects_altered_env1_line_chart_tempfile_fh_2, $effects_altered_env1_line_chart_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env1_line_chart_tempfile_2) || die "Can't open file ".$effects_altered_env1_line_chart_tempfile_2;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_altered_env_1_2->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim1_blup_vals_2, $val;
                }
            }
        close($F_pheno);

        my $sim1_blup_stat_2 = Statistics::Descriptive::Full->new();
        $sim1_blup_stat_2->add_data(@sim1_blup_vals_2);
        my $sig_sim1_blup_2 = $sim1_blup_stat_2->variance();

        my @sim1_blup_vals_3;
        my ($effects_altered_env1_line_chart_tempfile_fh_3, $effects_altered_env1_line_chart_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env1_line_chart_tempfile_3) || die "Can't open file ".$effects_altered_env1_line_chart_tempfile_3;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_altered_env_1_3->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim1_blup_vals_3, $val;
                }
            }
        close($F_pheno);

        my $sim1_blup_stat_3 = Statistics::Descriptive::Full->new();
        $sim1_blup_stat_3->add_data(@sim1_blup_vals_3);
        my $sig_sim1_blup_3 = $sim1_blup_stat_3->variance();

        my @sim2_blup_vals;
        my ($effects_altered_env2_line_chart_tempfile_fh, $effects_altered_env2_line_chart_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env2_line_chart_tempfile) || die "Can't open file ".$effects_altered_env2_line_chart_tempfile;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_data_altered_env_2->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim2_blup_vals, $val;
                }
            }
        close($F_pheno);

        my $sim2_blup_stat = Statistics::Descriptive::Full->new();
        $sim2_blup_stat->add_data(@sim2_blup_vals);
        my $sig_sim2_blup = $sim2_blup_stat->variance();

        my @sim2_blup_vals_2;
        my ($effects_altered_env2_line_chart_tempfile_fh_2, $effects_altered_env2_line_chart_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env2_line_chart_tempfile_2) || die "Can't open file ".$effects_altered_env2_line_chart_tempfile_2;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_altered_env_2_2->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim2_blup_vals_2, $val;
                }
            }
        close($F_pheno);

        my $sim2_blup_stat_2 = Statistics::Descriptive::Full->new();
        $sim2_blup_stat_2->add_data(@sim2_blup_vals_2);
        my $sig_sim2_blup_2 = $sim2_blup_stat_2->variance();

        my @sim2_blup_vals_3;
        my ($effects_altered_env2_line_chart_tempfile_fh_3, $effects_altered_env2_line_chart_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env2_line_chart_tempfile_3) || die "Can't open file ".$effects_altered_env2_line_chart_tempfile_3;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_altered_env_2_3->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim2_blup_vals_3, $val;
                }
            }
        close($F_pheno);

        my $sim2_blup_stat_3 = Statistics::Descriptive::Full->new();
        $sim2_blup_stat_3->add_data(@sim2_blup_vals_3);
        my $sig_sim2_blup_3 = $sim2_blup_stat_3->variance();

        my @sim3_blup_vals;
        my ($effects_altered_env3_line_chart_tempfile_fh, $effects_altered_env3_line_chart_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env3_line_chart_tempfile) || die "Can't open file ".$effects_altered_env3_line_chart_tempfile;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_data_altered_env_3->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim3_blup_vals, $val;
                }
            }
        close($F_pheno);

        my $sim3_blup_stat = Statistics::Descriptive::Full->new();
        $sim3_blup_stat->add_data(@sim3_blup_vals);
        my $sig_sim3_blup = $sim3_blup_stat->variance();

        my @sim3_blup_vals_2;
        my ($effects_altered_env3_line_chart_tempfile_fh_2, $effects_altered_env3_line_chart_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env3_line_chart_tempfile_2) || die "Can't open file ".$effects_altered_env3_line_chart_tempfile_2;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_altered_env_3_2->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim3_blup_vals_2, $val;
                }
            }
        close($F_pheno);

        my $sim3_blup_stat_2 = Statistics::Descriptive::Full->new();
        $sim3_blup_stat_2->add_data(@sim3_blup_vals_2);
        my $sig_sim3_blup_2 = $sim3_blup_stat_2->variance();

        my @sim3_blup_vals_3;
        my ($effects_altered_env3_line_chart_tempfile_fh_3, $effects_altered_env3_line_chart_tempfile_3) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env3_line_chart_tempfile_3) || die "Can't open file ".$effects_altered_env3_line_chart_tempfile_3;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_altered_env_3_3->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim3_blup_vals_3, $val;
                }
            }
        close($F_pheno);

        my $sim3_blup_stat_3 = Statistics::Descriptive::Full->new();
        $sim3_blup_stat_3->add_data(@sim3_blup_vals_3);
        my $sig_sim3_blup_3 = $sim3_blup_stat_3->variance();

        my @sim4_blup_vals;
        my ($effects_altered_env4_line_chart_tempfile_fh, $effects_altered_env4_line_chart_tempfile) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env4_line_chart_tempfile) || die "Can't open file ".$effects_altered_env4_line_chart_tempfile;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names) {
                    my $val = $result_blup_data_altered_env_4->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim4_blup_vals, $val;
                }
            }
        close($F_pheno);

        my $sim4_blup_stat = Statistics::Descriptive::Full->new();
        $sim4_blup_stat->add_data(@sim4_blup_vals);
        my $sig_sim4_blup = $sim4_blup_stat->variance();

        my @sim4_blup_vals_2;
        my ($effects_altered_env4_line_chart_tempfile_fh_2, $effects_altered_env4_line_chart_tempfile_2) = tempfile("drone_stats_XXXXX", DIR=> $tmp_stats_dir);
        open($F_pheno, ">", $effects_altered_env4_line_chart_tempfile_2) || die "Can't open file ".$effects_altered_env4_line_chart_tempfile_2;
            print $F_pheno "germplasmName,time,value\n";
            foreach my $p (@sorted_germplasm_names) {
                foreach my $t (@sorted_trait_names_2) {
                    my $val = $result_blup_data_altered_env_4_2->{$p}->{$t}->[0];
                    my @row = ($p, $trait_to_time_map_2{$t}, $val);
                    my $line = join ',', @row;
                    print $F_pheno "$line\n";
                    push @sim4_blup_vals_2, $val;
                }
            }
        close($F_pheno);

        my $sim4_blup_stat_2 = Statistics::Descriptive::Full->new();
        $sim4_blup_stat_2->add_data(@sim4_blup_vals_2);
        my $sig_sim4_blup_2 = $sim4_blup_stat_2->variance();

        my @set = ('0' ..'9', 'A' .. 'F');
        my @colors;
        for (1..scalar(@sorted_germplasm_names)) {
            my $str = join '' => map $set[rand @set], 1 .. 6;
            push @colors, '#'.$str;
        }
        my $color_string = join '\',\'', @colors;

        my $genetic_effects_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $genetic_effects_figure_tempfile_string .= '.png';
        my $genetic_effects_figure_tempfile = $c->config->{basepath}."/".$genetic_effects_figure_tempfile_string;

        my $genetic_effects_alt_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $genetic_effects_alt_figure_tempfile_string .= '.png';
        my $genetic_effects_alt_figure_tempfile = $c->config->{basepath}."/".$genetic_effects_alt_figure_tempfile_string;

        my $genetic_effects_alt_env1_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $genetic_effects_alt_env1_figure_tempfile_string .= '.png';
        my $genetic_effects_alt_env1_figure_tempfile = $c->config->{basepath}."/".$genetic_effects_alt_env1_figure_tempfile_string;

        my $genetic_effects_alt_env2_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $genetic_effects_alt_env2_figure_tempfile_string .= '.png';
        my $genetic_effects_alt_env2_figure_tempfile = $c->config->{basepath}."/".$genetic_effects_alt_env2_figure_tempfile_string;

        my $genetic_effects_alt_env3_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $genetic_effects_alt_env3_figure_tempfile_string .= '.png';
        my $genetic_effects_alt_env3_figure_tempfile = $c->config->{basepath}."/".$genetic_effects_alt_env3_figure_tempfile_string;

        my $genetic_effects_alt_env4_figure_tempfile_string = $c->tempfile( TEMPLATE => 'tmp_drone_statistics/figureXXXX');
        $genetic_effects_alt_env4_figure_tempfile_string .= '.png';
        my $genetic_effects_alt_env4_figure_tempfile = $c->config->{basepath}."/".$genetic_effects_alt_env4_figure_tempfile_string;

        my $cmd_gen_plot = 'R -e "library(data.table); library(ggplot2); library(GGally); library(gridExtra);
        mat <- fread(\''.$effects_original_line_chart_tempfile.'\', header=TRUE, sep=\',\');
        mat\$time <- as.numeric(as.character(mat\$time));
        options(device=\'png\');
        par();
        sp <- ggplot(mat, aes(x = time, y = value)) +
            geom_line(aes(color = germplasmName), size = 1) +
            scale_fill_manual(values = c(\''.$color_string.'\')) +
            theme_minimal();
        sp <- sp + guides(shape = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + guides(color = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + theme(legend.title = element_text(size = 3), legend.text = element_text(size = 3));
        sp <- sp + labs(title = \'Original Genetic Effects\');';
        if (scalar(@sorted_germplasm_names) > 100) {
            $cmd_gen_plot .= 'sp <- sp + theme(legend.position = \'none\');';
        }
        $cmd_gen_plot .= 'ggsave(\''.$genetic_effects_figure_tempfile.'\', sp, device=\'png\', width=12, height=6, units=\'in\');
        "';
        print STDERR Dumper $cmd_gen_plot;
        my $status_gen_plot = system($cmd_gen_plot);
        push @$spatial_effects_plots, $genetic_effects_figure_tempfile_string;

        my $cmd_gen_alt_plot = 'R -e "library(data.table); library(ggplot2); library(GGally); library(gridExtra);
        mat <- fread(\''.$effects_altered_line_chart_tempfile.'\', header=TRUE, sep=\',\');
        mat\$time <- as.numeric(as.character(mat\$time));
        options(device=\'png\');
        par();
        sp <- ggplot(mat, aes(x = time, y = value)) +
            geom_line(aes(color = germplasmName), size = 1) +
            scale_fill_manual(values = c(\''.$color_string.'\')) +
            theme_minimal();
        sp <- sp + guides(shape = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + guides(color = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + theme(legend.title = element_text(size = 3), legend.text = element_text(size = 3));
        sp <- sp + labs(title = \'Altered Genetic Effects\');';
        if (scalar(@sorted_germplasm_names) > 100) {
            $cmd_gen_alt_plot .= 'sp <- sp + theme(legend.position = \'none\');';
        }
        $cmd_gen_alt_plot .= 'ggsave(\''.$genetic_effects_alt_figure_tempfile.'\', sp, device=\'png\', width=12, height=6, units=\'in\');
        "';
        print STDERR Dumper $cmd_gen_alt_plot;
        my $status_gen_alt_plot = system($cmd_gen_alt_plot);
        push @$spatial_effects_plots, $genetic_effects_alt_figure_tempfile_string;

        my $cmd_gen_env1_plot = 'R -e "library(data.table); library(ggplot2); library(GGally); library(gridExtra);
        mat <- fread(\''.$effects_altered_env1_line_chart_tempfile.'\', header=TRUE, sep=\',\');
        mat\$time <- as.numeric(as.character(mat\$time));
        options(device=\'png\');
        par();
        sp <- ggplot(mat, aes(x = time, y = value)) +
            geom_line(aes(color = germplasmName), size = 1) +
            scale_fill_manual(values = c(\''.$color_string.'\')) +
            theme_minimal();
        sp <- sp + guides(shape = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + guides(color = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + theme(legend.title = element_text(size = 3), legend.text = element_text(size = 3));
        sp <- sp + labs(title = \'SimLinear Genetic Effects\');';
        if (scalar(@sorted_germplasm_names) > 100) {
            $cmd_gen_env1_plot .= 'sp <- sp + theme(legend.position = \'none\');';
        }
        $cmd_gen_env1_plot .= 'ggsave(\''.$genetic_effects_alt_env1_figure_tempfile.'\', sp, device=\'png\', width=12, height=6, units=\'in\');
        "';
        print STDERR Dumper $cmd_gen_env1_plot;
        my $status_gen_env1_plot = system($cmd_gen_env1_plot);
        push @$spatial_effects_plots, $genetic_effects_alt_env1_figure_tempfile_string;

        my $cmd_gen_env2_plot = 'R -e "library(data.table); library(ggplot2); library(GGally); library(gridExtra);
        mat <- fread(\''.$effects_altered_env2_line_chart_tempfile.'\', header=TRUE, sep=\',\');
        mat\$time <- as.numeric(as.character(mat\$time));
        options(device=\'png\');
        par();
        sp <- ggplot(mat, aes(x = time, y = value)) +
            geom_line(aes(color = germplasmName), size = 1) +
            scale_fill_manual(values = c(\''.$color_string.'\')) +
            theme_minimal();
        sp <- sp + guides(shape = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + guides(color = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + theme(legend.title = element_text(size = 3), legend.text = element_text(size = 3));
        sp <- sp + labs(title = \'Sim1DN Genetic Effects\');';
        if (scalar(@sorted_germplasm_names) > 100) {
            $cmd_gen_env2_plot .= 'sp <- sp + theme(legend.position = \'none\');';
        }
        $cmd_gen_env2_plot .= 'ggsave(\''.$genetic_effects_alt_env2_figure_tempfile.'\', sp, device=\'png\', width=12, height=6, units=\'in\');
        "';
        print STDERR Dumper $cmd_gen_env2_plot;
        my $status_gen_env2_plot = system($cmd_gen_env2_plot);
        push @$spatial_effects_plots, $genetic_effects_alt_env2_figure_tempfile_string;

        my $cmd_gen_env3_plot = 'R -e "library(data.table); library(ggplot2); library(GGally); library(gridExtra);
        mat <- fread(\''.$effects_altered_env3_line_chart_tempfile.'\', header=TRUE, sep=\',\');
        mat\$time <- as.numeric(as.character(mat\$time));
        options(device=\'png\');
        par();
        sp <- ggplot(mat, aes(x = time, y = value)) +
            geom_line(aes(color = germplasmName), size = 1) +
            scale_fill_manual(values = c(\''.$color_string.'\')) +
            theme_minimal();
        sp <- sp + guides(shape = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + guides(color = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + theme(legend.title = element_text(size = 3), legend.text = element_text(size = 3));
        sp <- sp + labs(title = \'Sim2DN Genetic Effects\');';
        if (scalar(@sorted_germplasm_names) > 100) {
            $cmd_gen_env3_plot .= 'sp <- sp + theme(legend.position = \'none\');';
        }
        $cmd_gen_env3_plot .= 'ggsave(\''.$genetic_effects_alt_env3_figure_tempfile.'\', sp, device=\'png\', width=12, height=6, units=\'in\');
        "';
        print STDERR Dumper $cmd_gen_env3_plot;
        my $status_gen_env3_plot = system($cmd_gen_env3_plot);
        push @$spatial_effects_plots, $genetic_effects_alt_env3_figure_tempfile_string;

        my $cmd_gen_env4_plot = 'R -e "library(data.table); library(ggplot2); library(GGally); library(gridExtra);
        mat <- fread(\''.$effects_altered_env4_line_chart_tempfile.'\', header=TRUE, sep=\',\');
        mat\$time <- as.numeric(as.character(mat\$time));
        options(device=\'png\');
        par();
        sp <- ggplot(mat, aes(x = time, y = value)) +
            geom_line(aes(color = germplasmName), size = 1) +
            scale_fill_manual(values = c(\''.$color_string.'\')) +
            theme_minimal();
        sp <- sp + guides(shape = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + guides(color = guide_legend(override.aes = list(size = 0.5)));
        sp <- sp + theme(legend.title = element_text(size = 3), legend.text = element_text(size = 3));
        sp <- sp + labs(title = \'SimRandom Genetic Effects\');';
        if (scalar(@sorted_germplasm_names) > 100) {
            $cmd_gen_env4_plot .= 'sp <- sp + theme(legend.position = \'none\');';
        }
        $cmd_gen_env4_plot .= 'ggsave(\''.$genetic_effects_alt_env4_figure_tempfile.'\', sp, device=\'png\', width=12, height=6, units=\'in\');
        "';
        print STDERR Dumper $cmd_gen_env4_plot;
        my $status_gen_env4_plot = system($cmd_gen_env4_plot);
        push @$spatial_effects_plots, $genetic_effects_alt_env4_figure_tempfile_string;
    };

    my $original_h2 = $residual_sum_square_original ? $genetic_effect_sum_square_original/$residual_sum_square_original : 'NA';
    my $altered_h2 = $residual_sum_square_altered ? $genetic_effect_sum_square_altered/$residual_sum_square_altered : 'NA';
    my $sim1_h2 = $residual_sum_square_altered_env ? $genetic_effect_sum_square_altered_env/$residual_sum_square_altered_env : 'NA';
    my $sim2_h2 = $residual_sum_square_altered_env_2 ? $genetic_effect_sum_square_altered_env_2/$residual_sum_square_altered_env_2 : 'NA';
    my $sim3_h2 = $residual_sum_square_altered_env_3 ? $genetic_effect_sum_square_altered_env_3/$residual_sum_square_altered_env_3 : 'NA';
    my $sim4_h2 = $residual_sum_square_altered_env_4 ? $genetic_effect_sum_square_altered_env_4/$residual_sum_square_altered_env_4 : 'NA';

    $c->stash->{rest} = {
        result_blup_genetic_data_original => $result_blup_data_original,
        result_blup_genetic_data_altered => $result_blup_data_altered,
        result_blup_genetic_data_altered_env => $result_blup_data_altered_env,
        result_blup_spatial_data_original => $result_blup_spatial_data_original,
        result_blup_spatial_data_altered => $result_blup_spatial_data_altered,
        result_blup_spatial_data_altered_env => $result_blup_spatial_data_altered_env,
        result_blup_pe_data_original => $result_blup_pe_data_original,
        result_blup_pe_data_altered => $result_blup_pe_data_altered,
        result_blup_pe_data_altered_env => $result_blup_pe_data_altered_env,
        result_residual_data_original => $result_residual_data_original,
        result_residual_data_altered => $result_residual_data_altered,
        result_residual_data_altered_env => $result_residual_data_altered_env,
        result_fitted_data_original => $result_fitted_data_original,
        result_fitted_data_altered => $result_fitted_data_altered,
        result_fitted_data_altered_env => $result_fitted_data_altered_env,
        unique_traits => \@sorted_trait_names,
        unique_residual_traits => \@sorted_residual_trait_names,
        unique_accessions => \@unique_accession_names,
        unique_plots => \@unique_plot_names,
        statistics_select => $statistics_select,
        grm_file => $grm_file,
        stats_tempfile => $stats_tempfile,
        blupf90_grm_file => $grm_rename_tempfile,
        blupf90_param_file => $parameter_tempfile,
        blupf90_training_file => $stats_tempfile_2,
        blupf90_permanent_environment_structure_file => $permanent_environment_structure_tempfile,
        yhat_residual_tempfile => $yhat_residual_tempfile,
        rr_genetic_coefficients => $coeff_genetic_tempfile,
        rr_pe_coefficients => $coeff_pe_tempfile,
        blupf90_solutions => $blupf90_solutions_tempfile,
        stats_out_tempfile => $stats_out_tempfile,
        stats_out_tempfile_string => $stats_out_tempfile_string,
        stats_out_htp_rel_tempfile_out_string => $stats_out_htp_rel_tempfile_out_string,
        stats_out_tempfile_col => $stats_out_tempfile_col,
        stats_out_tempfile_row => $stats_out_tempfile_row,
        statistical_ontology_term => $statistical_ontology_term,
        analysis_model_type => $statistics_select,
        analysis_model_language => $analysis_model_language,
        application_name => "NickMorales Mixed Models Analytics",
        application_version => "V1.01",
        analysis_model_training_data_file_type => $analysis_model_training_data_file_type,
        field_trial_design => $field_trial_design,
        trait_composing_info => \%trait_composing_info,
        sum_square_residual_original => $model_sum_square_residual_original,
        sum_square_residual_altered => $model_sum_square_residual_altered,
        sum_square_residual_altered_env => $model_sum_square_residual_altered_env,
        genetic_effect_sum_original => $genetic_effect_sum_original,
        genetic_effect_sum_altered => $genetic_effect_sum_altered,
        genetic_effect_sum_altered_env => $genetic_effect_sum_altered_env,
        env_effect_sum_original => $env_effect_sum_original,
        env_effect_sum_altered => $env_effect_sum_altered,
        env_effect_sum_altered_env => $env_effect_sum_altered_env,
        spatial_effects_plots => $spatial_effects_plots,
        simulated_environment_to_effect_correlations => \@env_corr_res,
        original_h2 => $original_h2,
        altered_h2 => $altered_h2,
        sim1_h2 => $sim1_h2,
        sim2_h2 => $sim2_h2,
        sim3_h2 => $sim3_h2,
        sim4_h2 => $sim4_h2,
    };
}

sub _perform_drone_imagery_analytics {
    my ($c, $schema, $env_factor, $a_env, $b_env, $ro_env, $row_ro_env, $env_variance_percent, $protocol_id, $statistics_select, $analytics_select, $tolparinv, $use_area_under_curve, $env_simulation, $legendre_order_number, $permanent_environment_structure, $legendre_coeff_exec_array, $trait_name_encoder_hash, $trait_name_encoder_rev_hash, $stock_info_hash, $plot_id_map_hash, $sorted_trait_names_array, $accession_id_factor_map_hash, $rep_time_factors_array, $ind_rep_factors_array, $unique_accession_names_array, $plot_id_count_map_reverse_hash, $sorted_scaled_ln_times_array, $time_count_map_reverse_hash, $accession_id_factor_map_reverse_hash, $seen_times_hash, $plot_id_factor_map_reverse_hash, $trait_to_time_map_hash, $unique_plot_names_array, $stock_name_row_col_hash, $phenotype_data_original_hash, $plot_rep_time_factor_map_hash, $stock_row_col_hash, $stock_row_col_id_hash, $polynomial_map_hash, $plot_ids_ordered_array, $csv, $timestamp, $user_name, $stats_tempfile, $grm_file, $grm_rename_tempfile, $tmp_stats_dir, $stats_out_tempfile, $stats_out_tempfile_row, $stats_out_tempfile_col, $stats_out_tempfile_residual, $stats_out_tempfile_2dspl, $stats_prep2_tempfile, $stats_out_param_tempfile, $parameter_tempfile, $parameter_asreml_tempfile, $stats_tempfile_2, $permanent_environment_structure_tempfile, $permanent_environment_structure_env_tempfile, $permanent_environment_structure_env_tempfile2, $permanent_environment_structure_env_tempfile_mat, $yhat_residual_tempfile, $blupf90_solutions_tempfile, $coeff_genetic_tempfile, $coeff_pe_tempfile, $time_min, $time_max, $header_string, $env_sim_exec, $min_row, $max_row, $min_col, $max_col, $mean_row, $sig_row, $mean_col, $sig_col) = @_;
    my @legendre_coeff_exec = @$legendre_coeff_exec_array;
    my %trait_name_encoder = %$trait_name_encoder_hash;
    my %trait_name_encoder_rev = %$trait_name_encoder_rev_hash;
    my %stock_info = %$stock_info_hash;
    my %plot_id_map = %$plot_id_map_hash;
    my @sorted_trait_names = @$sorted_trait_names_array;
    my %accession_id_factor_map = %$accession_id_factor_map_hash;
    my @rep_time_factors = @$rep_time_factors_array;
    my @unique_accession_names = @$unique_accession_names_array;
    my @ind_rep_factors = @$ind_rep_factors_array;
    my %plot_id_count_map_reverse = %$plot_id_count_map_reverse_hash;
    my @sorted_scaled_ln_times = @$sorted_scaled_ln_times_array;
    my %time_count_map_reverse = %$time_count_map_reverse_hash;
    my %seen_times = %$seen_times_hash;
    my %accession_id_factor_map_reverse = %$accession_id_factor_map_reverse_hash;
    my %plot_id_factor_map_reverse = %$plot_id_factor_map_reverse_hash;
    my %trait_to_time_map = %$trait_to_time_map_hash;
    my @unique_plot_names = @$unique_plot_names_array;
    my %stock_name_row_col = %$stock_name_row_col_hash;
    my %phenotype_data_original = %$phenotype_data_original_hash;
    my %plot_rep_time_factor_map = %$plot_rep_time_factor_map_hash;
    my %stock_row_col = %$stock_row_col_hash;
    my %stock_row_col_id = %$stock_row_col_id_hash;
    my %polynomial_map = %$polynomial_map_hash;
    my @plot_ids_ordered = @$plot_ids_ordered_array;

    print STDERR "CALC $permanent_environment_structure\n";

    my ($statistical_ontology_term, $analysis_model_training_data_file_type, $analysis_model_language, @sorted_residual_trait_names, %rr_unique_traits, %rr_residual_unique_traits, $statistics_cmd, $cmd_f90, $cmd_asreml, $number_traits, $number_accessions);

    my ($result_blup_data_original, $result_blup_data_delta_original, $result_blup_spatial_data_original, $result_blup_pe_data_original, $result_blup_pe_data_delta_original, $result_residual_data_original, $result_fitted_data_original, %fixed_effects_original, %rr_genetic_coefficients_original, %rr_temporal_coefficients_original);
    my $model_sum_square_residual_original = 0;
    my $genetic_effect_min_original = 1000000000;
    my $genetic_effect_max_original = -1000000000;
    my $env_effect_min_original = 1000000000;
    my $env_effect_max_original = -1000000000;
    my $genetic_effect_sum_square_original = 0;
    my $genetic_effect_sum_original = 0;
    my $env_effect_sum_square_original = 0;
    my $env_effect_sum_original = 0;
    my $residual_sum_square_original = 0;
    my $residual_sum_original = 0;

    print STDERR "RUN FIRST ENV ESTIMATION\n";
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups') {
        $statistical_ontology_term = "Multivariate linear mixed model genetic BLUPs using genetic relationship matrix and row and column spatial effects computed using Sommer R|SGNSTAT:0000001"; #In the JS this is set to either the genetic or spatial BLUP term (Multivariate linear mixed model 2D spline spatial BLUPs using genetic relationship matrix and row and column spatial effects computed using Sommer R|SGNSTAT:0000003) when saving analysis results

        $analysis_model_language = "R";
        $analysis_model_training_data_file_type = "nicksmixedmodelsanalytics_v1.01_sommer_grm_spatial_genetic_blups_phenotype_file";

        my @encoded_traits = values %trait_name_encoder;
        my $encoded_trait_string = join ',', @encoded_traits;
        $number_traits = scalar(@encoded_traits);
        my $cbind_string = $number_traits > 1 ? "cbind($encoded_trait_string)" : $encoded_trait_string;

        $statistics_cmd = 'R -e "library(sommer); library(data.table); library(reshape2);
        mat <- data.frame(fread(\''.$stats_tempfile.'\', header=TRUE, sep=\',\'));
        geno_mat_3col <- data.frame(fread(\''.$grm_file.'\', header=FALSE, sep=\'\t\'));
        geno_mat <- acast(geno_mat_3col, V1~V2, value.var=\'V3\');
        geno_mat[is.na(geno_mat)] <- 0;
        mat\$rowNumber <- as.numeric(mat\$rowNumber);
        mat\$colNumber <- as.numeric(mat\$colNumber);
        mat\$rowNumberFactor <- as.factor(mat\$rowNumberFactor);
        mat\$colNumberFactor <- as.factor(mat\$colNumberFactor);
        mix <- mmer('.$cbind_string.'~1 + replicate, random=~vs(id, Gu=geno_mat, Gtc=unsm('.$number_traits.')) +vs(rowNumberFactor, Gtc=diag('.$number_traits.')) +vs(colNumberFactor, Gtc=diag('.$number_traits.')) +vs(spl2D(rowNumber, colNumber), Gtc=diag('.$number_traits.')), rcov=~vs(units, Gtc=unsm('.$number_traits.')), data=mat, tolparinv='.$tolparinv.');
        if (!is.null(mix\$U)) {
        #gen_cor <- cov2cor(mix\$sigma\$\`u:id\`);
        write.table(mix\$U\$\`u:id\`, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
        write.table(mix\$U\$\`u:rowNumberFactor\`, file=\''.$stats_out_tempfile_row.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
        write.table(mix\$U\$\`u:colNumberFactor\`, file=\''.$stats_out_tempfile_col.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
        write.table(data.frame(plot_id = mix\$data\$plot_id, residuals = mix\$residuals, fitted = mix\$fitted), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
        X <- with(mat, spl2D(rowNumber, colNumber));
        spatial_blup_results <- data.frame(plot_id = mat\$plot_id);
        ';
        my $trait_index = 1;
        foreach my $enc_trait_name (@encoded_traits) {
            $statistics_cmd .= '
        blups'.$trait_index.' <- mix\$U\$\`u:rowNumber\`\$'.$enc_trait_name.';
        spatial_blup_results\$'.$enc_trait_name.' <- data.matrix(X) %*% data.matrix(blups'.$trait_index.');
            ';
            $trait_index++;
        }
        $statistics_cmd .= 'write.table(spatial_blup_results, file=\''.$stats_out_tempfile_2dspl.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
        }
        "';
        # print STDERR Dumper $statistics_cmd;
        eval {
            my $status = system($statistics_cmd);
        };
        my $run_stats_fault = 0;
        if ($@) {
            print STDERR "R ERROR\n";
            print STDERR Dumper $@;
            $run_stats_fault = 1;
        }
        else {
            my $current_gen_row_count = 0;
            my $current_env_row_count = 0;

            open(my $fh, '<', $stats_out_tempfile)
                or die "Could not open file '$stats_out_tempfile' $!";

                print STDERR "Opened $stats_out_tempfile\n";
                my $header = <$fh>;
                my @header_cols;
                if ($csv->parse($header)) {
                    @header_cols = $csv->fields();
                }

                while (my $row = <$fh>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $stock_id = $columns[0];

                        my $stock_name = $stock_info{$stock_id}->{uniquename};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_data_original->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $genetic_effect_min_original) {
                                $genetic_effect_min_original = $value;
                            }
                            elsif ($value >= $genetic_effect_max_original) {
                                $genetic_effect_max_original = $value;
                            }

                            $genetic_effect_sum_original += abs($value);
                            $genetic_effect_sum_square_original = $genetic_effect_sum_square_original + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_gen_row_count++;
                }
            close($fh);

            open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                print STDERR "Opened $stats_out_tempfile_2dspl\n";
                my $header_2dspl = <$fh_2dspl>;
                my @header_cols_2dspl;
                if ($csv->parse($header_2dspl)) {
                    @header_cols_2dspl = $csv->fields();
                }
                shift @header_cols_2dspl;
                while (my $row_2dspl = <$fh_2dspl>) {
                    my @columns;
                    if ($csv->parse($row_2dspl)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols_2dspl) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $plot_id = $columns[0];

                        my $plot_name = $plot_id_map{$plot_id};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_spatial_data_original->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $env_effect_min_original) {
                                $env_effect_min_original = $value;
                            }
                            elsif ($value >= $env_effect_max_original) {
                                $env_effect_max_original = $value;
                            }

                            $env_effect_sum_original += abs($value);
                            $env_effect_sum_square_original = $env_effect_sum_square_original + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_env_row_count++;
                }
            close($fh_2dspl);

            open(my $fh_residual, '<', $stats_out_tempfile_residual)
                or die "Could not open file '$stats_out_tempfile_residual' $!";
            
                print STDERR "Opened $stats_out_tempfile_residual\n";
                my $header_residual = <$fh_residual>;
                my @header_cols_residual;
                if ($csv->parse($header_residual)) {
                    @header_cols_residual = $csv->fields();
                }
                while (my $row = <$fh_residual>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }

                    my $stock_id = $columns[0];
                    foreach (0..$number_traits-1) {
                        my $trait_name = $sorted_trait_names[$_];
                        my $residual = $columns[1 + $_];
                        my $fitted = $columns[1 + $number_traits + $_];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_original->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_original += abs($residual);
                            $residual_sum_square_original = $residual_sum_square_original + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_original->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_original = $model_sum_square_residual_original + $residual*$residual;
                    }
                }
            close($fh_residual);

            if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                $run_stats_fault = 1;
            }
        }

        if ($run_stats_fault == 1) {
            $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
            $c->detach();
            print STDERR "ERROR IN R CMD\n";
        }
    }
    elsif ($statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups') {
        $statistical_ontology_term = "Univariate linear mixed model genetic BLUPs using genetic relationship matrix and row and column spatial effects computed using Sommer R|SGNSTAT:0000001"; #In the JS this is set to either the genetic or spatial BLUP term (Multivariate linear mixed model 2D spline spatial BLUPs using genetic relationship matrix and row and column spatial effects computed using Sommer R|SGNSTAT:0000003) when saving analysis results

        $analysis_model_language = "R";
        $analysis_model_training_data_file_type = "nicksmixedmodelsanalytics_v1.01_sommer_grm_univariate_spatial_genetic_blups_phenotype_file";

        my @encoded_traits = values %trait_name_encoder;
        $number_traits = scalar(@encoded_traits);
        foreach my $t (@encoded_traits) {

            $statistics_cmd = 'R -e "library(sommer); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_file.'\', header=FALSE, sep=\'\t\'));
            geno_mat <- acast(geno_mat_3col, V1~V2, value.var=\'V3\');
            geno_mat[is.na(geno_mat)] <- 0;
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumberFactor);
            mat\$colNumberFactor <- as.factor(mat\$colNumberFactor);
            mix <- mmer('.$t.'~1 + replicate, random=~vs(id, Gu=geno_mat, Gtc=unsm(1)) +vs(rowNumberFactor, Gtc=diag(1)) +vs(colNumberFactor, Gtc=diag(1)) +vs(spl2D(rowNumber, colNumber), Gtc=diag(1)), rcov=~vs(units, Gtc=unsm(1)), data=mat, tolparinv='.$tolparinv.');
            if (!is.null(mix\$U)) {
            #gen_cor <- cov2cor(mix\$sigma\$\`u:id\`);
            write.table(mix\$U\$\`u:id\`, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:rowNumberFactor\`, file=\''.$stats_out_tempfile_row.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:colNumberFactor\`, file=\''.$stats_out_tempfile_col.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mix\$data\$plot_id, residuals = mix\$residuals, fitted = mix\$fitted), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            X <- with(mat, spl2D(rowNumber, colNumber));
            spatial_blup_results <- data.frame(plot_id = mat\$plot_id);
            blups1 <- mix\$U\$\`u:rowNumber\`\$'.$t.';
            spatial_blup_results\$'.$t.' <- data.matrix(X) %*% data.matrix(blups1);
            write.table(spatial_blup_results, file=\''.$stats_out_tempfile_2dspl.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            # print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };
            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;

                open(my $fh, '<', $stats_out_tempfile)
                    or die "Could not open file '$stats_out_tempfile' $!";

                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;
                    my @header_cols;
                    if ($csv->parse($header)) {
                        @header_cols = $csv->fields();
                    }

                    while (my $row = <$fh>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $stock_id = $columns[0];

                                my $stock_name = $stock_info{$stock_id}->{uniquename};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_data_original->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $genetic_effect_min_original) {
                                        $genetic_effect_min_original = $value;
                                    }
                                    elsif ($value >= $genetic_effect_max_original) {
                                        $genetic_effect_max_original = $value;
                                    }

                                    $genetic_effect_sum_original += abs($value);
                                    $genetic_effect_sum_square_original = $genetic_effect_sum_square_original + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_gen_row_count++;
                    }
                close($fh);

                open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                    or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                    print STDERR "Opened $stats_out_tempfile_2dspl\n";
                    my $header_2dspl = <$fh_2dspl>;
                    my @header_cols_2dspl;
                    if ($csv->parse($header_2dspl)) {
                        @header_cols_2dspl = $csv->fields();
                    }
                    shift @header_cols_2dspl;
                    while (my $row_2dspl = <$fh_2dspl>) {
                        my @columns;
                        if ($csv->parse($row_2dspl)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols_2dspl) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $plot_id = $columns[0];

                                my $plot_name = $plot_id_map{$plot_id};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_spatial_data_original->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $env_effect_min_original) {
                                        $env_effect_min_original = $value;
                                    }
                                    elsif ($value >= $env_effect_max_original) {
                                        $env_effect_max_original = $value;
                                    }

                                    $env_effect_sum_original += abs($value);
                                    $env_effect_sum_square_original = $env_effect_sum_square_original + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_env_row_count++;
                    }
                close($fh_2dspl);

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $trait_name = $trait_name_encoder_rev{$t};
                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_original->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_original += abs($residual);
                            $residual_sum_square_original = $residual_sum_square_original + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_original->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_original = $model_sum_square_residual_original + $residual*$residual;
                    }
                close($fh_residual);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {

        $analysis_model_language = "F90";

        $statistical_ontology_term = "Multivariate linear mixed model genetic BLUPs using genetic relationship matrix and temporal Legendre polynomial random regression on days after planting computed using Sommer R|SGNSTAT:0000004"; #In the JS this is set to either the genetic of permanent environment BLUP term (Multivariate linear mixed model permanent environment BLUPs using genetic relationship matrix and temporal Legendre polynomial random regression on days after planting computed using Sommer R|SGNSTAT:0000005) when saving results
    
        if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups') {
            $analysis_model_training_data_file_type = "nicksmixedmodelsanalytics_v1.01_blupf90_grm_temporal_leg_random_regression_GDD_genetic_blups_phenotype_file";
        }
        elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups') {
            $analysis_model_training_data_file_type = "nicksmixedmodelsanalytics_v1.01_blupf90_grm_temporal_leg_random_regression_DAP_genetic_blups_phenotype_file";
        }
        elsif ($statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
            $analysis_model_training_data_file_type = "nicksmixedmodelsanalytics_v1.01_airemlf90_grm_temporal_leg_random_regression_GDD_genetic_blups_phenotype_file";
        }
        elsif ($statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
            $analysis_model_training_data_file_type = "nicksmixedmodelsanalytics_v1.01_airemlf90_grm_temporal_leg_random_regression_DAP_genetic_blups_phenotype_file";
        }

        my $pheno_var_pos = $legendre_order_number+1;

        $statistics_cmd = 'R -e "
            pheno <- read.csv(\''.$stats_prep2_tempfile.'\', header=FALSE, sep=\',\');
            v <- var(pheno);
            v <- v[1:'.$pheno_var_pos.', 1:'.$pheno_var_pos.'];
            #v <- matrix(rep(0.1, '.$pheno_var_pos.'*'.$pheno_var_pos.'), nrow = '.$pheno_var_pos.');
            #diag(v) <- rep(1, '.$pheno_var_pos.');
            write.table(v, file=\''.$stats_out_param_tempfile.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');
        "';
        my $status_r = system($statistics_cmd);

        my @pheno_var;
        open(my $fh_r, '<', $stats_out_param_tempfile)
            or die "Could not open file '$stats_out_param_tempfile' $!";
            print STDERR "Opened $stats_out_param_tempfile\n";

            while (my $row = <$fh_r>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                push @pheno_var, \@columns;
            }
        close($fh_r);
        # print STDERR Dumper \@pheno_var;

        my @grm_old;
        open(my $fh_grm_old, '<', $grm_file)
            or die "Could not open file '$grm_file' $!";
            print STDERR "Opened $grm_file\n";

            while (my $row = <$fh_grm_old>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                push @grm_old, \@columns;
            }
        close($fh_grm_old);

        my %grm_hash_ordered;
        foreach (@grm_old) {
            my $l1 = $accession_id_factor_map{$_->[0]};
            my $l2 = $accession_id_factor_map{$_->[1]};
            my $val = sprintf("%.8f", $_->[2]);
            if ($l1 < $l2) {
                $grm_hash_ordered{$l1}->{$l2} = $val;
            }
            else {
                $grm_hash_ordered{$l2}->{$l1} = $val;
            }
        }

        open(my $fh_grm_new, '>', $grm_rename_tempfile)
            or die "Could not open file '$grm_rename_tempfile' $!";
            print STDERR "Opened $grm_rename_tempfile\n";

            foreach my $i (sort keys %grm_hash_ordered) {
                my $v = $grm_hash_ordered{$i};
                foreach my $j (sort keys %$v) {
                    my $val = $v->{$j};
                    print $fh_grm_new "$i $j $val\n";
                }
            }
        close($fh_grm_new);

        my $stats_tempfile_2_basename = basename($stats_tempfile_2);
        my $grm_file_basename = basename($grm_rename_tempfile);
        my $permanent_environment_structure_file_basename = basename($permanent_environment_structure_tempfile);
        #my @phenotype_header = ("id", "plot_id", "replicate", "time", "replicate_time", "ind_replicate", @sorted_trait_names, "phenotype");

        my $effect_1_levels = scalar(@rep_time_factors);
        my $effect_grm_levels = scalar(@unique_accession_names);
        my $effect_pe_levels = scalar(@ind_rep_factors);

        my @param_file_rows = (
            'DATAFILE',
            $stats_tempfile_2_basename,
            'NUMBER_OF_TRAITS',
            '1',
            'NUMBER_OF_EFFECTS',
            ($legendre_order_number + 1)*2 + 1,
            'OBSERVATION(S)',
            $legendre_order_number + 1 + 6 + 1,
            'WEIGHT(S)',
            '',
            'EFFECTS: POSITION_IN_DATAFILE NUMBER_OF_LEVELS TYPE_OF_EFFECT',
            '5 '.$effect_1_levels.' cross',
        );
        my $p_counter = 1;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p_counter.' '.$effect_grm_levels.' cov 1';
            $p_counter++;
        }
        my $p2_counter = 1;
        my @hetres_group;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p2_counter.' '.$effect_pe_levels.' cov 6';
            push @hetres_group, 6+$p2_counter;
            $p2_counter++;
        }
        my @random_group1;
        foreach (1..$legendre_order_number+1) {
            push @random_group1, 1+$_;
        }
        my $random_group_string1 = join ' ', @random_group1;
        my @random_group2;
        foreach (1..$legendre_order_number+1) {
            push @random_group2, 1+scalar(@random_group1)+$_;
        }
        my $random_group_string2 = join ' ', @random_group2;
        my $hetres_group_string = join ' ', @hetres_group;
        push @param_file_rows, (
            'RANDOM_RESIDUAL VALUES',
            '1',
            'RANDOM_GROUP',
            $random_group_string1,
            'RANDOM_TYPE'
        );
        if (!$protocol_id) {
            push @param_file_rows, (
                'diagonal',
                'FILE',
                ''
            );
        }
        else {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $grm_file_basename
            );
        }
        push @param_file_rows, (
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        push @param_file_rows, (
            'RANDOM_GROUP',
            $random_group_string2,
            'RANDOM_TYPE'
        );

        if ($permanent_environment_structure eq 'identity' || $permanent_environment_structure eq 'env_corr_structure') {
            push @param_file_rows, (
                'diagonal',
                'FILE',
                ''
            );
        }
        else {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_file_basename
            );
        }

        push @param_file_rows, (
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        my $hetres_pol_string = join ' ', @sorted_scaled_ln_times;
        push @param_file_rows, (
            'OPTION hetres_pos '.$hetres_group_string,
            'OPTION hetres_pol '.$hetres_pol_string,
            'OPTION conv_crit '.$tolparinv,
            'OPTION residual',
        );

        open(my $Fp, ">", $parameter_tempfile) || die "Can't open file ".$parameter_tempfile;
            foreach (@param_file_rows) {
                print $Fp "$_\n";
            }
        close($Fp);

        my $command_name = '';
        if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups') {
            $command_name = 'blupf90';
        }
        elsif ($statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
            $command_name = 'airemlf90';
        }

        my $parameter_tempfile_basename = basename($parameter_tempfile);
        $stats_out_tempfile .= '.log';
        $cmd_f90 = 'cd '.$tmp_stats_dir.'; echo '.$parameter_tempfile_basename.' | '.$command_name.' > '.$stats_out_tempfile;
        print STDERR Dumper $cmd_f90;
        my $status = system($cmd_f90);

        open(my $fh_log, '<', $stats_out_tempfile)
            or die "Could not open file '$stats_out_tempfile' $!";

            print STDERR "Opened $stats_out_tempfile\n";
            while (my $row = <$fh_log>) {
                print STDERR $row;
            }
        close($fh_log);

        my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
        my $h_time = $schema->storage->dbh()->prepare($q_time);

        $yhat_residual_tempfile = $tmp_stats_dir."/yhat_residual";
        open(my $fh_yhat_res, '<', $yhat_residual_tempfile)
            or die "Could not open file '$yhat_residual_tempfile' $!";
            print STDERR "Opened $yhat_residual_tempfile\n";

            my $pred_res_counter = 0;
            my $trait_counter = 0;
            while (my $row = <$fh_yhat_res>) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $pred = $vals[0];
                my $residual = $vals[1];
                $model_sum_square_residual_original = $model_sum_square_residual_original + $residual*$residual;

                my $plot_name = $plot_id_count_map_reverse{$pred_res_counter};
                my $time = $time_count_map_reverse{$pred_res_counter};

                $rr_residual_unique_traits{$seen_times{$time}}++;

                if (defined $residual && $residual ne '') {
                    $result_residual_data_original->{$plot_name}->{$seen_times{$time}} = [$residual, $timestamp, $user_name, '', ''];
                    $residual_sum_original += abs($residual);
                    $residual_sum_square_original = $residual_sum_square_original + $residual*$residual;
                }
                if (defined $pred && $pred ne '') {
                    $result_fitted_data_original->{$plot_name}->{$seen_times{$time}} = [$pred, $timestamp, $user_name, '', ''];
                }

                $pred_res_counter++;
            }
        close($fh_yhat_res);

        $blupf90_solutions_tempfile = $tmp_stats_dir."/solutions";
        open(my $fh_sol, '<', $blupf90_solutions_tempfile)
            or die "Could not open file '$blupf90_solutions_tempfile' $!";
            print STDERR "Opened $blupf90_solutions_tempfile\n";

            my $head = <$fh_sol>;
            print STDERR $head;

            my $solution_file_counter = 0;
            my $grm_sol_counter = 0;
            my $grm_sol_trait_counter = 0;
            my $pe_sol_counter = 0;
            my $pe_sol_trait_counter = 0;
            while (defined(my $row = <$fh_sol>)) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $level = $vals[2];
                my $value = $vals[3];
                if ($solution_file_counter < $effect_1_levels) {
                    $fixed_effects_original{$solution_file_counter}->{$level} = $value;
                }
                elsif ($solution_file_counter < $effect_1_levels + $effect_grm_levels*($legendre_order_number+1)) {
                    my $accession_name = $accession_id_factor_map_reverse{$level};
                    if ($grm_sol_counter < $effect_grm_levels-1) {
                        $grm_sol_counter++;
                    }
                    else {
                        $grm_sol_counter = 0;
                        $grm_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_genetic_coefficients_original{$accession_name}}, $value;
                    }
                }
                else {
                    my $plot_name = $plot_id_factor_map_reverse{$level};
                    if ($pe_sol_counter < $effect_pe_levels-1) {
                        $pe_sol_counter++;
                    }
                    else {
                        $pe_sol_counter = 0;
                        $pe_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_temporal_coefficients_original{$plot_name}}, $value;
                    }
                }
                $solution_file_counter++;
            }
        close($fh_sol);

        # print STDERR Dumper \%rr_genetic_coefficients;
        # print STDERR Dumper \%rr_temporal_coefficients;

        open(my $Fgc, ">", $coeff_genetic_tempfile) || die "Can't open file ".$coeff_genetic_tempfile;
        print STDERR "OPENED $coeff_genetic_tempfile\n";

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_original) {
            my @line = ($accession_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fgc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_blup = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');
                $rr_unique_traits{$time_term_string_blup}++;

                $trait_to_time_map{$time_term_string_blup} = $time_rescaled;

                $result_blup_data_original->{$accession_name}->{$time_term_string_blup} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fgc);

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_original) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_data_delta_original->{$accession_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $genetic_effect_min_original) {
                    $genetic_effect_min_original = $value;
                }
                elsif ($value >= $genetic_effect_max_original) {
                    $genetic_effect_max_original = $value;
                }

                $genetic_effect_sum_original += abs($value);
                $genetic_effect_sum_square_original = $genetic_effect_sum_square_original + $value*$value;
            }
        }

        open(my $Fpc, ">", $coeff_pe_tempfile) || die "Can't open file ".$coeff_pe_tempfile;
        print STDERR "OPENED $coeff_pe_tempfile\n";

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_original) {
            my @line = ($plot_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fpc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_pe = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $trait_to_time_map{$time_term_string_pe} = $time_rescaled;

                $result_blup_pe_data_original->{$plot_name}->{$time_term_string_pe} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fpc);

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_original) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_pe_data_delta_original->{$plot_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $env_effect_min_original) {
                    $env_effect_min_original = $value;
                }
                elsif ($value >= $env_effect_max_original) {
                    $env_effect_max_original = $value;
                }

                $env_effect_sum_original += abs($value);
                $env_effect_sum_square_original = $env_effect_sum_square_original + $value*$value;
            }
        }
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        $analysis_model_language = "R";

        $statistical_ontology_term = "Univariate linear mixed model 2D spline genetic BLUPs using genetic relationship matrix and row and column spatial effects computed using Sommer R|SGNSTAT:0000038"; #In the JS this is set to either Univariate linear mixed model 2D spline spatial BLUPs using genetic relationship matrix and row and column spatial effects computed using Sommer R|SGNSTAT:0000039
    
        $analysis_model_training_data_file_type = "nicksmixedmodelsanalytics_v1.01_asreml_grm_univariate_spatial_genetic_blups_phenotype_file";

        my @grm_old;
        open(my $fh_grm_old, '<', $grm_file)
            or die "Could not open file '$grm_file' $!";
            print STDERR "Opened $grm_file\n";

            while (my $row = <$fh_grm_old>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                push @grm_old, \@columns;
            }
        close($fh_grm_old);

        my %grm_hash_ordered;
        foreach (@grm_old) {
            my $l1 = $accession_id_factor_map{$_->[0]};
            my $l2 = $accession_id_factor_map{$_->[1]};
            my $val = sprintf("%.8f", $_->[2]);
            if ($l1 > $l2) {
                $grm_hash_ordered{$l1}->{$l2} = $val;
            }
            else {
                $grm_hash_ordered{$l2}->{$l1} = $val;
            }
        }

        open(my $fh_grm_new, '>', $grm_rename_tempfile) or die "Could not open file '$grm_rename_tempfile' $!";
            print STDERR "Opened $grm_rename_tempfile\n";

            foreach my $i (sort keys %grm_hash_ordered) {
                my $v = $grm_hash_ordered{$i};
                foreach my $j (sort keys %$v) {
                    my $val = $v->{$j};
                    print $fh_grm_new "$i $j $val\n";
                }
            }
        close($fh_grm_new);

        # foreach my $time (@sorted_trait_names) {
        #     my @param_file_rows = (
        #         '!NOGRAPHICS !DEBUG !QUIET',
        #         'Single Trait analysis',
        #         ' id !I',
        #         ' plot_id !I',
        #         ' replicate !I',
        #         ' rowNumber !I',
        #         ' colNumber !I',
        #         ' id_factor !I',
        #         ' plot_id_factor !I'
        #     );
        #     foreach my $t (@sorted_trait_names) {
        #         push @param_file_rows, " t$t";
        #     }
        #     push @param_file_rows, (
        #         "$grm_file_basename !NSD",
        #         "$stats_tempfile_2_basename !CSV !SKIP 1 !MVINCLUDE !MAXIT 200 !EXTRA 5",
        #         '',
        #         "t$time ~ mu replicate !r grm1(id_factor) ar1(rowNumber).ar1v(colNumber)",
        #     );
        # 
        #     open(my $Fp, ">", $parameter_asreml_tempfile) || die "Can't open file ".$parameter_asreml_tempfile;
        #         print STDERR "WRITE ASREML PARAMFILE $parameter_asreml_tempfile\n";
        #         foreach (@param_file_rows) {
        #             print $Fp "$_\n";
        #         }
        #     close($Fp);
        # 
        #     my $parameter_asreml_tempfile_basename = basename($parameter_asreml_tempfile);
        #     $stats_out_tempfile .= '.log';
        #     $cmd_asreml = 'cd '.$tmp_stats_dir.'; asreml '.$parameter_asreml_tempfile_basename.' > '.$stats_out_tempfile;
        #     print STDERR Dumper $cmd_asreml;
        #     my $status = system($cmd_asreml);
        # }

        #my @phenotype_header = ("id", "plot_id", "replicate", "rowNumber", "colNumber"", "id_factor", "plot_id_factor", "t@times");

        my @encoded_traits = values %trait_name_encoder;
        $number_traits = scalar(@sorted_trait_names);
        $number_accessions = scalar(@unique_accession_names);
        foreach my $t (@sorted_trait_names) {

            $statistics_cmd = 'R -e "library(asreml); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile_2.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_rename_tempfile.'\', header=FALSE, sep=\' \'));
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumber);
            mat\$colNumberFactor <- as.factor(mat\$colNumber);
            mat\$id_factor <- as.factor(mat\$id_factor);
            mat <- mat[order(mat\$rowNumber, mat\$colNumber),];
            attr(geno_mat_3col,\'rowNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'colNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'INVERSE\') <- TRUE;
            mix <- asreml(t'.$t.'~1 + replicate, random=~vm(id_factor, geno_mat_3col) + ar1(rowNumberFactor):ar1v(colNumberFactor), residual=~idv(units), data=mat);
            if (!is.null(summary(mix,coef=TRUE)\$coef.random)) {
            write.table(summary(mix,coef=TRUE)\$coef.random, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mat\$plot_id, residuals = mix\$residuals, fitted = mix\$linear.predictors), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };

            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;
                my @row_col_ordered_plots_names;

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        push @row_col_ordered_plots_names, $stock_name;
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_original->{$stock_name}->{$t} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_original += abs($residual);
                            $residual_sum_square_original = $residual_sum_square_original + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_original->{$stock_name}->{$t} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_original = $model_sum_square_residual_original + $residual*$residual;
                    }
                close($fh_residual);

                open(my $fh, '<', $stats_out_tempfile) or die "Could not open file '$stats_out_tempfile' $!";
                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;

                    my $solution_file_counter = 0;
                    while (defined(my $row = <$fh>)) {
                        # print STDERR $row;
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $level = $columns[0];
                        my $value = $columns[1];
                        my $std = $columns[2];
                        my $z_ratio = $columns[3];
                        if (defined $value && $value ne '') {
                            if ($solution_file_counter < $number_accessions) {
                                my $stock_name = $accession_id_factor_map_reverse{$solution_file_counter+1};
                                $result_blup_data_original->{$stock_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $genetic_effect_min_original) {
                                    $genetic_effect_min_original = $value;
                                }
                                elsif ($value >= $genetic_effect_max_original) {
                                    $genetic_effect_max_original = $value;
                                }

                                $genetic_effect_sum_original += abs($value);
                                $genetic_effect_sum_square_original = $genetic_effect_sum_square_original + $value*$value;

                                $current_gen_row_count++;
                            }
                            else {
                                my $plot_name = $row_col_ordered_plots_names[$current_env_row_count-$number_accessions];
                                $result_blup_spatial_data_original->{$plot_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $env_effect_min_original) {
                                    $env_effect_min_original = $value;
                                }
                                elsif ($value >= $env_effect_max_original) {
                                    $env_effect_max_original = $value;
                                }

                                $env_effect_sum_original += abs($value);
                                $env_effect_sum_square_original = $env_effect_sum_square_original + $value*$value;

                                $current_env_row_count++;
                            }
                        }
                        $solution_file_counter++;
                    }
                close($fh);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    print STDERR "ORIGINAL $statistics_select GENETIC EFFECT SUM $genetic_effect_sum_original\n";
    print STDERR "ORIGINAL $statistics_select ENV EFFECT SUM $env_effect_sum_original\n";print STDERR Dumper [$genetic_effect_min_original, $genetic_effect_max_original, $env_effect_min_original, $env_effect_max_original];

    my (%phenotype_data_altered, @data_matrix_altered, @data_matrix_phenotypes_altered, @phenotype_data_altered_values);
    my $phenotype_min_altered = 1000000000;
    my $phenotype_max_altered = -1000000000;
    my $phenotype_variance_altered;

    print STDERR "SUBTRACT ENV ESTIMATE\n";
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_genetic_blups' || $statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my @row = ($replicate, $block, "S".$germplasm_stock_id, $obsunit_stock_id, $row_number, $col_number, $row_number, $col_number);

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_original{$p}->{$t})) {
                    my $minimizer = 0;
                    if ($analytics_select eq 'minimize_local_env_effect') {
                        $minimizer = $result_blup_spatial_data_original->{$p}->{$t}->[0];
                    }
                    elsif ($analytics_select eq 'minimize_genetic_effect') {
                        $minimizer = $result_blup_data_original->{$p}->{$t}->[0];
                    }
                    my $new_val = $phenotype_data_original{$p}->{$t} + 0 - $minimizer;

                    if ($new_val < $phenotype_min_altered) {
                        $phenotype_min_altered = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered) {
                        $phenotype_max_altered = $new_val;
                    }

                    push @phenotype_data_altered_values, $new_val;
                    $phenotype_data_altered{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, 'NA';
                }
            }
            push @data_matrix_altered, \@row;
        }

        open(my $F, ">", $stats_tempfile) || die "Can't open file ".$stats_tempfile;
            print $F $header_string."\n";
            foreach (@data_matrix_altered) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @data_matrix_phenotypes_row;
            my $current_trait_index = 0;
            foreach my $t (@sorted_trait_names) {
                my @row = (
                    $accession_id_factor_map{$germplasm_stock_id},
                    $obsunit_stock_id,
                    $replicate,
                    $t,
                    $plot_rep_time_factor_map{$obsunit_stock_id}->{$replicate}->{$t},
                    $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
                );

                my $polys = $polynomial_map{$t};
                push @row, @$polys;

                if (defined($phenotype_data_original{$p}->{$t})) {
                    if ($use_area_under_curve) {
                        my $val = 0;
                        foreach my $counter (0..$current_trait_index) {
                            if ($counter == 0) {
                                $val = $val + $phenotype_data_original{$p}->{$sorted_trait_names[$counter]} + 0;
                            }
                            else {
                                my $t1 = $sorted_trait_names[$counter-1];
                                my $t2 = $sorted_trait_names[$counter];
                                my $p1 = $phenotype_data_original{$p}->{$t1} + 0;
                                my $p2 = $phenotype_data_original{$p}->{$t2} + 0;
                                my $neg = 1;
                                my $min_val = $p1;
                                if ($p2 < $p1) {
                                    $neg = -1;
                                    $min_val = $p2;
                                }
                                $val = $val + (($neg*($p2-$p1)*($t2-$t1))/2)+($t2-$t1)*$min_val;
                            }
                        }

                        my $minimizer = 0;
                        if ($analytics_select eq 'minimize_local_env_effect') {
                            $minimizer = $result_blup_pe_data_delta_original->{$p}->{$t}->[0];
                            # $minimizer = $minimizer * ($phenotype_max_original - $phenotype_min_original)/($env_effect_max_original - $env_effect_min_original);
                        }
                        elsif ($analytics_select eq 'minimize_genetic_effect') {
                            $minimizer = $result_blup_data_delta_original->{$p}->{$t}->[0];
                            # $minimizer = $minimizer * ($phenotype_max_original - $phenotype_min_original)/($genetic_effect_max_original - $genetic_effect_min_original);
                        }
                        my $new_val = $val - $minimizer;

                        if ($new_val < $phenotype_min_altered) {
                            $phenotype_min_altered = $new_val;
                        }
                        elsif ($new_val >= $phenotype_max_altered) {
                            $phenotype_max_altered = $new_val;
                        }

                        push @phenotype_data_altered_values, $new_val;
                        $phenotype_data_altered{$p}->{$t} = $new_val;
                        push @row, $new_val;
                        push @data_matrix_phenotypes_row, $new_val;
                    }
                    else {
                        my $val = $phenotype_data_original{$p}->{$t} + 0;

                        my $minimizer = 0;
                        if ($analytics_select eq 'minimize_local_env_effect') {
                            $minimizer = $result_blup_pe_data_delta_original->{$p}->{$t}->[0];
                        }
                        elsif ($analytics_select eq 'minimize_genetic_effect') {
                            $minimizer = $result_blup_data_delta_original->{$p}->{$t}->[0];
                        }
                        my $new_val = $val - $minimizer;

                        if ($new_val < $phenotype_min_altered) {
                            $phenotype_min_altered = $new_val;
                        }
                        elsif ($new_val >= $phenotype_max_altered) {
                            $phenotype_max_altered = $new_val;
                        }

                        push @phenotype_data_altered_values, $new_val;
                        $phenotype_data_altered{$p}->{$t} = $new_val;
                        push @row, $new_val;
                        push @data_matrix_phenotypes_row, $new_val;
                    }
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                    push @data_matrix_phenotypes_row, 'NA';
                }

                push @data_matrix_altered, \@row;
                push @data_matrix_phenotypes_altered, \@data_matrix_phenotypes_row;

                $current_trait_index++;
            }
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            foreach (@data_matrix_altered) {
                my $line = join ' ', @$_;
                print $F "$line\n";
            }
        close($F);

        open(my $F2, ">", $stats_prep2_tempfile) || die "Can't open file ".$stats_prep2_tempfile;
            foreach (@data_matrix_phenotypes_altered) {
                my $line = join ',', @$_;
                print $F2 "$line\n";
            }
        close($F2);
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @row = (
                $germplasm_stock_id,
                $obsunit_stock_id,
                $replicate,
                $row_number,
                $col_number,
                $accession_id_factor_map{$germplasm_stock_id},
                $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
            );

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_original{$p}->{$t})) {
                    my $val = $phenotype_data_original{$p}->{$t} + 0;

                    my $minimizer = 0;
                    if ($analytics_select eq 'minimize_local_env_effect') {
                        $minimizer = $result_blup_spatial_data_original->{$p}->{$t}->[0];
                    }
                    elsif ($analytics_select eq 'minimize_genetic_effect') {
                        $minimizer = $result_blup_data_original->{$p}->{$t}->[0];
                    }
                    my $new_val = $val - $minimizer;

                    if ($new_val < $phenotype_min_altered) {
                        $phenotype_min_altered = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered) {
                        $phenotype_max_altered = $new_val;
                    }

                    push @phenotype_data_altered_values, $new_val;
                    $phenotype_data_altered{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                }
            }
            push @data_matrix_altered, \@row;
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            print $F $header_string."\n";
            foreach (@data_matrix_altered) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }

    my $phenotypes_altered_stat = Statistics::Descriptive::Full->new();
    $phenotypes_altered_stat->add_data(@phenotype_data_altered_values);
    $phenotype_variance_altered = $phenotypes_altered_stat->variance();

    print STDERR Dumper [$phenotype_min_altered, $phenotype_max_altered];

    my ($result_blup_data_altered, $result_blup_data_delta_altered, $result_blup_spatial_data_altered, $result_blup_pe_data_altered, $result_blup_pe_data_delta_altered, $result_residual_data_altered, $result_fitted_data_altered, %fixed_effects_altered, %rr_genetic_coefficients_altered, %rr_temporal_coefficients_altered);
    my $model_sum_square_residual_altered = 0;
    my $genetic_effect_min_altered = 1000000000;
    my $genetic_effect_max_altered = -1000000000;
    my $env_effect_min_altered = 1000000000;
    my $env_effect_max_altered = -1000000000;
    my $genetic_effect_sum_square_altered = 0;
    my $genetic_effect_sum_altered = 0;
    my $env_effect_sum_square_altered = 0;
    my $env_effect_sum_altered = 0;
    my $residual_sum_square_altered = 0;
    my $residual_sum_altered = 0;

    print STDERR "RUN ENV ESTIMATE ON ALTERED PHENO\n";
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups') {
        # print STDERR Dumper $statistics_cmd;
        eval {
            my $status = system($statistics_cmd);
        };
        my $run_stats_fault = 0;
        if ($@) {
            print STDERR "R ERROR\n";
            print STDERR Dumper $@;
            $run_stats_fault = 1;
        }
        else {
            my $current_gen_row_count = 0;
            my $current_env_row_count = 0;

            open(my $fh, '<', $stats_out_tempfile)
                or die "Could not open file '$stats_out_tempfile' $!";

                print STDERR "Opened $stats_out_tempfile\n";
                my $header = <$fh>;
                my @header_cols;
                if ($csv->parse($header)) {
                    @header_cols = $csv->fields();
                }

                while (my $row = <$fh>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $stock_id = $columns[0];

                        my $stock_name = $stock_info{$stock_id}->{uniquename};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_data_altered->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $genetic_effect_min_altered) {
                                $genetic_effect_min_altered = $value;
                            }
                            elsif ($value >= $genetic_effect_max_altered) {
                                $genetic_effect_max_altered = $value;
                            }

                            $genetic_effect_sum_altered += abs($value);
                            $genetic_effect_sum_square_altered = $genetic_effect_sum_square_altered + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_gen_row_count++;
                }
            close($fh);

            open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                print STDERR "Opened $stats_out_tempfile_2dspl\n";
                my $header_2dspl = <$fh_2dspl>;
                my @header_cols_2dspl;
                if ($csv->parse($header_2dspl)) {
                    @header_cols_2dspl = $csv->fields();
                }
                shift @header_cols_2dspl;
                while (my $row_2dspl = <$fh_2dspl>) {
                    my @columns;
                    if ($csv->parse($row_2dspl)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols_2dspl) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $plot_id = $columns[0];

                        my $plot_name = $plot_id_map{$plot_id};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_spatial_data_altered->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $env_effect_min_altered) {
                                $env_effect_min_altered = $value;
                            }
                            elsif ($value >= $env_effect_max_altered) {
                                $env_effect_max_altered = $value;
                            }

                            $env_effect_sum_altered += abs($value);
                            $env_effect_sum_square_altered = $env_effect_sum_square_altered + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_env_row_count++;
                }
            close($fh_2dspl);

            open(my $fh_residual, '<', $stats_out_tempfile_residual)
                or die "Could not open file '$stats_out_tempfile_residual' $!";
            
                print STDERR "Opened $stats_out_tempfile_residual\n";
                my $header_residual = <$fh_residual>;
                my @header_cols_residual;
                if ($csv->parse($header_residual)) {
                    @header_cols_residual = $csv->fields();
                }
                while (my $row = <$fh_residual>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }

                    my $stock_id = $columns[0];
                    foreach (0..$number_traits-1) {
                        my $trait_name = $sorted_trait_names[$_];
                        my $residual = $columns[1 + $_];
                        my $fitted = $columns[1 + $number_traits + $_];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered += abs($residual);
                            $residual_sum_square_altered = $residual_sum_square_altered + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered = $model_sum_square_residual_altered + $residual*$residual;
                    }
                }
            close($fh_residual);

            if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                $run_stats_fault = 1;
            }
        }

        if ($run_stats_fault == 1) {
            $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
            $c->detach();
            print STDERR "ERROR IN R CMD\n";
        }
    }
    elsif ($statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups') {
        my @encoded_traits = values %trait_name_encoder;
        foreach my $t (@encoded_traits) {

            $statistics_cmd = 'R -e "library(sommer); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_file.'\', header=FALSE, sep=\'\t\'));
            geno_mat <- acast(geno_mat_3col, V1~V2, value.var=\'V3\');
            geno_mat[is.na(geno_mat)] <- 0;
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumberFactor);
            mat\$colNumberFactor <- as.factor(mat\$colNumberFactor);
            mix <- mmer('.$t.'~1 + replicate, random=~vs(id, Gu=geno_mat, Gtc=unsm(1)) +vs(rowNumberFactor, Gtc=diag(1)) +vs(colNumberFactor, Gtc=diag(1)) +vs(spl2D(rowNumber, colNumber), Gtc=diag(1)), rcov=~vs(units, Gtc=unsm(1)), data=mat, tolparinv='.$tolparinv.');
            if (!is.null(mix\$U)) {
            #gen_cor <- cov2cor(mix\$sigma\$\`u:id\`);
            write.table(mix\$U\$\`u:id\`, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:rowNumberFactor\`, file=\''.$stats_out_tempfile_row.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:colNumberFactor\`, file=\''.$stats_out_tempfile_col.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mix\$data\$plot_id, residuals = mix\$residuals, fitted = mix\$fitted), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            X <- with(mat, spl2D(rowNumber, colNumber));
            spatial_blup_results <- data.frame(plot_id = mat\$plot_id);
            blups1 <- mix\$U\$\`u:rowNumber\`\$'.$t.';
            spatial_blup_results\$'.$t.' <- data.matrix(X) %*% data.matrix(blups1);
            write.table(spatial_blup_results, file=\''.$stats_out_tempfile_2dspl.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            # print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };
            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;

                open(my $fh, '<', $stats_out_tempfile)
                    or die "Could not open file '$stats_out_tempfile' $!";

                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;
                    my @header_cols;
                    if ($csv->parse($header)) {
                        @header_cols = $csv->fields();
                    }

                    while (my $row = <$fh>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $stock_id = $columns[0];

                                my $stock_name = $stock_info{$stock_id}->{uniquename};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_data_altered->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $genetic_effect_min_altered) {
                                        $genetic_effect_min_altered = $value;
                                    }
                                    elsif ($value >= $genetic_effect_max_altered) {
                                        $genetic_effect_max_altered = $value;
                                    }

                                    $genetic_effect_sum_altered += abs($value);
                                    $genetic_effect_sum_square_altered = $genetic_effect_sum_square_altered + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_gen_row_count++;
                    }
                close($fh);

                open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                    or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                    print STDERR "Opened $stats_out_tempfile_2dspl\n";
                    my $header_2dspl = <$fh_2dspl>;
                    my @header_cols_2dspl;
                    if ($csv->parse($header_2dspl)) {
                        @header_cols_2dspl = $csv->fields();
                    }
                    shift @header_cols_2dspl;
                    while (my $row_2dspl = <$fh_2dspl>) {
                        my @columns;
                        if ($csv->parse($row_2dspl)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols_2dspl) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $plot_id = $columns[0];

                                my $plot_name = $plot_id_map{$plot_id};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_spatial_data_altered->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $env_effect_min_altered) {
                                        $env_effect_min_altered = $value;
                                    }
                                    elsif ($value >= $env_effect_max_altered) {
                                        $env_effect_max_altered = $value;
                                    }

                                    $env_effect_sum_altered += abs($value);
                                    $env_effect_sum_square_altered = $env_effect_sum_square_altered + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_env_row_count++;
                    }
                close($fh_2dspl);

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $trait_name = $trait_name_encoder_rev{$t};
                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered += abs($residual);
                            $residual_sum_square_altered = $residual_sum_square_altered + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered = $model_sum_square_residual_altered + $residual*$residual;
                    }
                close($fh_residual);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {

        print STDERR Dumper $statistics_cmd;
        my $status_r = system($statistics_cmd);

        my @pheno_var;
        open(my $fh_r, '<', $stats_out_param_tempfile)
            or die "Could not open file '$stats_out_param_tempfile' $!";
            print STDERR "Opened $stats_out_param_tempfile\n";

            while (my $row = <$fh_r>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                push @pheno_var, \@columns;
            }
        close($fh_r);
        # print STDERR Dumper \@pheno_var;

        my $stats_tempfile_2_basename = basename($stats_tempfile_2);
        my $grm_file_basename = basename($grm_rename_tempfile);
        my $permanent_environment_structure_file_basename = basename($permanent_environment_structure_tempfile);
        #my @phenotype_header = ("id", "plot_id", "replicate", "time", "replicate_time", "ind_replicate", @sorted_trait_names, "phenotype");

        my $effect_1_levels = scalar(@rep_time_factors);
        my $effect_grm_levels = scalar(@unique_accession_names);
        my $effect_pe_levels = scalar(@ind_rep_factors);

        my @param_file_rows = (
            'DATAFILE',
            $stats_tempfile_2_basename,
            'NUMBER_OF_TRAITS',
            '1',
            'NUMBER_OF_EFFECTS',
            ($legendre_order_number + 1)*2 + 1,
            'OBSERVATION(S)',
            $legendre_order_number + 1 + 6 + 1,
            'WEIGHT(S)',
            '',
            'EFFECTS: POSITION_IN_DATAFILE NUMBER_OF_LEVELS TYPE_OF_EFFECT',
            '5 '.$effect_1_levels.' cross',
        );
        my $p_counter = 1;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p_counter.' '.$effect_grm_levels.' cov 1';
            $p_counter++;
        }
        my $p2_counter = 1;
        my @hetres_group;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p2_counter.' '.$effect_pe_levels.' cov 6';
            push @hetres_group, 6+$p2_counter;
            $p2_counter++;
        }
        my @random_group1;
        foreach (1..$legendre_order_number+1) {
            push @random_group1, 1+$_;
        }
        my $random_group_string1 = join ' ', @random_group1;
        my @random_group2;
        foreach (1..$legendre_order_number+1) {
            push @random_group2, 1+scalar(@random_group1)+$_;
        }
        my $random_group_string2 = join ' ', @random_group2;
        my $hetres_group_string = join ' ', @hetres_group;
        push @param_file_rows, (
            'RANDOM_RESIDUAL VALUES',
            '1',
            'RANDOM_GROUP',
            $random_group_string1,
            'RANDOM_TYPE',
            'user_file_inv',
            'FILE',
            $grm_file_basename,
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        push @param_file_rows, (
            'RANDOM_GROUP',
            $random_group_string2,
            'RANDOM_TYPE'
        );

        if ($permanent_environment_structure eq 'identity' || $permanent_environment_structure eq 'env_corr_structure') {
            push @param_file_rows, (
                'diagonal',
                'FILE',
                ''
            );
        }
        else {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_file_basename
            );
        }

        push @param_file_rows, (
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        my $hetres_pol_string = join ' ', @sorted_scaled_ln_times;
        push @param_file_rows, (
            'OPTION hetres_pos '.$hetres_group_string,
            'OPTION hetres_pol '.$hetres_pol_string,
            'OPTION conv_crit '.$tolparinv,
            'OPTION residual',
        );

        open(my $Fp, ">", $parameter_tempfile) || die "Can't open file ".$parameter_tempfile;
            foreach (@param_file_rows) {
                print $Fp "$_\n";
            }
        close($Fp);

        print STDERR Dumper $cmd_f90;
        my $status = system($cmd_f90);

        open(my $fh_log, '<', $stats_out_tempfile)
            or die "Could not open file '$stats_out_tempfile' $!";

            print STDERR "Opened $stats_out_tempfile\n";
            while (my $row = <$fh_log>) {
                print STDERR $row;
            }
        close($fh_log);

        my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
        my $h_time = $schema->storage->dbh()->prepare($q_time);

        $yhat_residual_tempfile = $tmp_stats_dir."/yhat_residual";
        open(my $fh_yhat_res, '<', $yhat_residual_tempfile)
            or die "Could not open file '$yhat_residual_tempfile' $!";
            print STDERR "Opened $yhat_residual_tempfile\n";

            my $pred_res_counter = 0;
            my $trait_counter = 0;
            while (my $row = <$fh_yhat_res>) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $pred = $vals[0];
                my $residual = $vals[1];
                $model_sum_square_residual_altered = $model_sum_square_residual_altered + $residual*$residual;

                my $plot_name = $plot_id_count_map_reverse{$pred_res_counter};
                my $time = $time_count_map_reverse{$pred_res_counter};

                if (defined $residual && $residual ne '') {
                    $result_residual_data_altered->{$plot_name}->{$seen_times{$time}} = [$residual, $timestamp, $user_name, '', ''];
                    $residual_sum_altered += abs($residual);
                    $residual_sum_square_altered = $residual_sum_square_altered + $residual*$residual;
                }
                if (defined $pred && $pred ne '') {
                    $result_fitted_data_altered->{$plot_name}->{$seen_times{$time}} = [$pred, $timestamp, $user_name, '', ''];
                }

                $pred_res_counter++;
            }
        close($fh_yhat_res);

        $blupf90_solutions_tempfile = $tmp_stats_dir."/solutions";
        open(my $fh_sol, '<', $blupf90_solutions_tempfile)
            or die "Could not open file '$blupf90_solutions_tempfile' $!";
            print STDERR "Opened $blupf90_solutions_tempfile\n";

            my $head = <$fh_sol>;
            print STDERR $head;

            my $solution_file_counter = 0;
            my $grm_sol_counter = 0;
            my $grm_sol_trait_counter = 0;
            my $pe_sol_counter = 0;
            my $pe_sol_trait_counter = 0;
            while (defined(my $row = <$fh_sol>)) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $level = $vals[2];
                my $value = $vals[3];
                if ($solution_file_counter < $effect_1_levels) {
                    $fixed_effects_altered{$solution_file_counter}->{$level} = $value;
                }
                elsif ($solution_file_counter < $effect_1_levels + $effect_grm_levels*($legendre_order_number+1)) {
                    my $accession_name = $accession_id_factor_map_reverse{$level};
                    if ($grm_sol_counter < $effect_grm_levels-1) {
                        $grm_sol_counter++;
                    }
                    else {
                        $grm_sol_counter = 0;
                        $grm_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_genetic_coefficients_altered{$accession_name}}, $value;
                    }
                }
                else {
                    my $plot_name = $plot_id_factor_map_reverse{$level};
                    if ($pe_sol_counter < $effect_pe_levels-1) {
                        $pe_sol_counter++;
                    }
                    else {
                        $pe_sol_counter = 0;
                        $pe_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_temporal_coefficients_altered{$plot_name}}, $value;
                    }
                }
                $solution_file_counter++;
            }
        close($fh_sol);

        # print STDERR Dumper \%rr_genetic_coefficients_altered;
        # print STDERR Dumper \%rr_temporal_coefficients_altered;

        open(my $Fgc, ">", $coeff_genetic_tempfile) || die "Can't open file ".$coeff_genetic_tempfile;

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered) {
            my @line = ($accession_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fgc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_blup = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_data_altered->{$accession_name}->{$time_term_string_blup} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fgc);

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_data_delta_altered->{$accession_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $genetic_effect_min_altered) {
                    $genetic_effect_min_altered = $value;
                }
                elsif ($value >= $genetic_effect_max_altered) {
                    $genetic_effect_max_altered = $value;
                }

                $genetic_effect_sum_altered += abs($value);
                $genetic_effect_sum_square_altered = $genetic_effect_sum_square_altered + $value*$value;
            }
        }

        open(my $Fpc, ">", $coeff_pe_tempfile) || die "Can't open file ".$coeff_pe_tempfile;

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered) {
            my @line = ($plot_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fpc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_pe = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_pe_data_altered->{$plot_name}->{$time_term_string_pe} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fpc);

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_pe_data_delta_altered->{$plot_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $env_effect_min_altered) {
                    $env_effect_min_altered = $value;
                }
                elsif ($value >= $env_effect_max_altered) {
                    $env_effect_max_altered = $value;
                }

                $env_effect_sum_altered += abs($value);
                $env_effect_sum_square_altered = $env_effect_sum_square_altered + $value*$value;
            }
        }
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {

        foreach my $t (@sorted_trait_names) {

            $statistics_cmd = 'R -e "library(asreml); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile_2.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_rename_tempfile.'\', header=FALSE, sep=\' \'));
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumber);
            mat\$colNumberFactor <- as.factor(mat\$colNumber);
            mat\$id_factor <- as.factor(mat\$id_factor);
            mat <- mat[order(mat\$rowNumber, mat\$colNumber),];
            attr(geno_mat_3col,\'rowNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'colNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'INVERSE\') <- TRUE;
            mix <- asreml(t'.$t.'~1 + replicate, random=~vm(id_factor, geno_mat_3col) + ar1(rowNumberFactor):ar1v(colNumberFactor), residual=~idv(units), data=mat);
            if (!is.null(summary(mix,coef=TRUE)\$coef.random)) {
            write.table(summary(mix,coef=TRUE)\$coef.random, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mat\$plot_id, residuals = mix\$residuals, fitted = mix\$linear.predictors), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };

            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;
                my @row_col_ordered_plots_names;

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        push @row_col_ordered_plots_names, $stock_name;
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered->{$stock_name}->{$t} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered += abs($residual);
                            $residual_sum_square_altered = $residual_sum_square_altered + $residual*$residual;}
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered->{$stock_name}->{$t} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered = $model_sum_square_residual_altered + $residual*$residual;
                    }
                close($fh_residual);

                open(my $fh, '<', $stats_out_tempfile) or die "Could not open file '$stats_out_tempfile' $!";
                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;

                    my $solution_file_counter = 0;
                    while (defined(my $row = <$fh>)) {
                        # print STDERR $row;
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $level = $columns[0];
                        my $value = $columns[1];
                        my $std = $columns[2];
                        my $z_ratio = $columns[3];
                        if (defined $value && $value ne '') {
                            if ($solution_file_counter < $number_accessions) {
                                my $stock_name = $accession_id_factor_map_reverse{$solution_file_counter+1};
                                $result_blup_data_altered->{$stock_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $genetic_effect_min_altered) {
                                    $genetic_effect_min_altered = $value;
                                }
                                elsif ($value >= $genetic_effect_max_altered) {
                                    $genetic_effect_max_altered = $value;
                                }

                                $genetic_effect_sum_altered += abs($value);
                                $genetic_effect_sum_square_altered = $genetic_effect_sum_square_altered + $value*$value;

                                $current_gen_row_count++;
                            }
                            else {
                                my $plot_name = $row_col_ordered_plots_names[$current_env_row_count-$number_accessions];
                                $result_blup_spatial_data_altered->{$plot_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $env_effect_min_altered) {
                                    $env_effect_min_altered = $value;
                                }
                                elsif ($value >= $env_effect_max_altered) {
                                    $env_effect_max_altered = $value;
                                }

                                $env_effect_sum_altered += abs($value);
                                $env_effect_sum_square_altered = $env_effect_sum_square_altered + $value*$value;

                                $current_env_row_count++;
                            }
                        }
                        $solution_file_counter++;
                    }
                close($fh);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    print STDERR "ALTERED $statistics_select GENETIC EFFECT SUM $genetic_effect_sum_altered\n";
    print STDERR "ALTERED $statistics_select ENV EFFECT SUM $env_effect_sum_altered\n";
    print STDERR Dumper [$genetic_effect_min_altered, $genetic_effect_max_altered, $env_effect_min_altered, $env_effect_max_altered];

    my @sim_env_types = ("linear_gradient", "random_1d_normal_gradient", "random_2d_normal_gradient", "random", "ar1xar1", "row_plus_col");
    $env_simulation = "linear_gradient";

    my (%phenotype_data_altered_env, @data_matrix_altered_env, @data_matrix_phenotypes_altered_env);
    my $phenotype_min_altered_env = 1000000000;
    my $phenotype_max_altered_env = -1000000000;
    my $env_sim_min = 10000000000000;
    my $env_sim_max = -10000000000000;
    my %sim_data;
    my %sim_data_check_1;

    my %seen_rows;
    my %seen_cols;

    eval {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $sim_val = eval $env_sim_exec->{$env_simulation};

            $sim_data_check_1{$row_number}->{$col_number} = $sim_val;
            $seen_rows{$row_number}++;
            $seen_cols{$col_number}++;

            if ($sim_val < $env_sim_min) {
                $env_sim_min = $sim_val;
            }
            elsif ($sim_val >= $env_sim_max) {
                $env_sim_max = $sim_val;
            }
        }
    };

    my @seen_rows_ordered = sort keys %seen_rows;
    my @seen_cols_ordered = sort keys %seen_cols;

    if ($permanent_environment_structure eq 'env_corr_structure') {
        my @sim_data_diff_1;
        my $num_plots = scalar(@unique_plot_names);
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $plot_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my $sim_val = $sim_data_check_1{$row_number}->{$col_number};
            my @diffs = ($plot_id, $sim_val);
            foreach my $r (@seen_rows_ordered) {
                foreach my $c (@seen_cols_ordered) {
                    my $v = $sim_data_check_1{$r}->{$c};
                    push @diffs, $sim_val - $v;
                }
            }
            push @sim_data_diff_1, \@diffs;
        }

        open(my $pe_pheno_f, ">", $permanent_environment_structure_env_tempfile) || die "Can't open file ".$permanent_environment_structure_env_tempfile;
            print STDERR "OPENING PERMANENT ENVIRONMENT ENV $env_simulation CORR $permanent_environment_structure_env_tempfile\n";
            foreach (@sim_data_diff_1) {
                my $line = join "\t", @$_;
                print $pe_pheno_f $line."\n";
            }
        close($pe_pheno_f);

        my $pe_rel_cmd = 'R -e "library(lme4); library(data.table);
        mat_agg <- fread(\''.$permanent_environment_structure_env_tempfile.'\', header=FALSE, sep=\'\t\');
        mat_pheno <- mat_agg[,3:ncol(mat_agg)];
        a <- data.matrix(mat_pheno) - (matrix(rep(1,'.$num_plots.'*'.$num_plots.'), nrow='.$num_plots.') %*% data.matrix(mat_pheno))/'.$num_plots.';
        cor_mat <- a %*% t(a);
        rownames(cor_mat) <- data.matrix(mat_agg[,1]);
        colnames(cor_mat) <- data.matrix(mat_agg[,1]);
        range01 <- function(x){(x-min(x))/(max(x)-min(x))};
        cor_mat <- range01(cor_mat);
        write.table(cor_mat, file=\''.$permanent_environment_structure_env_tempfile2.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
        # print STDERR Dumper $pe_rel_cmd;
        my $status_pe_rel = system($pe_rel_cmd);

        my %rel_pe_result_hash;
        open(my $pe_rel_res, '<', $permanent_environment_structure_env_tempfile2) or die "Could not open file '$permanent_environment_structure_env_tempfile2' $!";
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE $permanent_environment_structure_env_tempfile2\n";
            my $header_row = <$pe_rel_res>;
            my @header;
            if ($csv->parse($header_row)) {
                @header = $csv->fields();
            }

            while (my $row = <$pe_rel_res>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                my $stock_id1 = $columns[0];
                my $counter = 1;
                foreach my $stock_id2 (@header) {
                    my $val = $columns[$counter];
                    $rel_pe_result_hash{$stock_id1}->{$stock_id2} = $val;
                    $counter++;
                }
            }
        close($pe_rel_res);

        my $data_rel_pe = '';
        my %result_hash_pe;
        foreach my $s (sort { $a <=> $b } @plot_ids_ordered) {
            foreach my $r (sort { $a <=> $b } @plot_ids_ordered) {
                my $s_factor = $stock_name_row_col{$plot_id_map{$s}}->{plot_id_factor};
                my $r_factor = $stock_name_row_col{$plot_id_map{$r}}->{plot_id_factor};
                if (!exists($result_hash_pe{$s_factor}->{$r_factor}) && !exists($result_hash_pe{$r_factor}->{$s_factor})) {
                    $result_hash_pe{$s_factor}->{$r_factor} = $rel_pe_result_hash{$s}->{$r};
                }
            }
        }
        foreach my $r (sort { $a <=> $b } keys %result_hash_pe) {
            foreach my $s (sort { $a <=> $b } keys %{$result_hash_pe{$r}}) {
                my $val = $result_hash_pe{$r}->{$s};
                if (defined $val and length $val) {
                    $data_rel_pe .= "$r\t$s\t$val\n";
                }
            }
        }

        open(my $pe_rel_out, ">", $permanent_environment_structure_env_tempfile_mat) || die "Can't open file ".$permanent_environment_structure_env_tempfile_mat;
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE 3col $permanent_environment_structure_env_tempfile_mat\n";
            print $pe_rel_out $data_rel_pe;
        close($pe_rel_out);
    }

    print STDERR "ADD SIMULATED ENV TO ALTERED PHENO linear_gradient\n";
    print STDERR Dumper [$env_sim_min, $env_sim_max];
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_genetic_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my @row = ($replicate, $block, "S".$germplasm_stock_id, $obsunit_stock_id, $row_number, $col_number, $row_number, $col_number);

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = eval $env_sim_exec->{$env_simulation};
                    $sim_val = (($sim_val - $env_sim_min)/($env_sim_max - $env_sim_min))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env) {
                        $phenotype_min_altered_env = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env) {
                        $phenotype_max_altered_env = $new_val;
                    }

                    $sim_data{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, 'NA';
                }
            }
            push @data_matrix_altered_env, \@row;
        }

        open(my $F, ">", $stats_tempfile) || die "Can't open file ".$stats_tempfile;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @data_matrix_phenotypes_row;
            my $current_trait_index = 0;
            foreach my $t (@sorted_trait_names) {
                my @row = (
                    $accession_id_factor_map{$germplasm_stock_id},
                    $obsunit_stock_id,
                    $replicate,
                    $t,
                    $plot_rep_time_factor_map{$obsunit_stock_id}->{$replicate}->{$t},
                    $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
                );

                my $polys = $polynomial_map{$t};
                push @row, @$polys;

                if (defined($phenotype_data_altered{$p}->{$t})) {
                    if ($use_area_under_curve) {
                        my $val = 0;
                        foreach my $counter (0..$current_trait_index) {
                            if ($counter == 0) {
                                $val = $val + $phenotype_data_altered{$p}->{$sorted_trait_names[$counter]} + 0;
                            }
                            else {
                                my $t1 = $sorted_trait_names[$counter-1];
                                my $t2 = $sorted_trait_names[$counter];
                                my $p1 = $phenotype_data_altered{$p}->{$t1} + 0;
                                my $p2 = $phenotype_data_altered{$p}->{$t2} + 0;
                                my $neg = 1;
                                my $min_val = $p1;
                                if ($p2 < $p1) {
                                    $neg = -1;
                                    $min_val = $p2;
                                }
                                $val = $val + (($neg*($p2-$p1)*($t2-$t1))/2)+($t2-$t1)*$min_val;
                            }
                        }

                        my $sim_val = eval $env_sim_exec->{$env_simulation};
                        $sim_val = (($sim_val - $env_sim_min)/($env_sim_max - $env_sim_min))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env) {
                            $phenotype_min_altered_env = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env) {
                            $phenotype_max_altered_env = $val;
                        }

                        $sim_data{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                    else {
                        my $val = $phenotype_data_altered{$p}->{$t} + 0;

                        my $sim_val = eval $env_sim_exec->{$env_simulation};
                        $sim_val = (($sim_val - $env_sim_min)/($env_sim_max - $env_sim_min))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env) {
                            $phenotype_min_altered_env = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env) {
                            $phenotype_max_altered_env = $val;
                        }

                        $sim_data{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                    push @data_matrix_phenotypes_row, 'NA';
                }

                push @data_matrix_altered_env, \@row;
                push @data_matrix_phenotypes_altered_env, \@data_matrix_phenotypes_row;

                $current_trait_index++;
            }
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            foreach (@data_matrix_altered_env) {
                my $line = join ' ', @$_;
                print $F "$line\n";
            }
        close($F);

        open(my $F2, ">", $stats_prep2_tempfile) || die "Can't open file ".$stats_prep2_tempfile;
            foreach (@data_matrix_phenotypes_altered_env) {
                my $line = join ',', @$_;
                print $F2 "$line\n";
            }
        close($F2);
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @row = (
                $germplasm_stock_id,
                $obsunit_stock_id,
                $replicate,
                $row_number,
                $col_number,
                $accession_id_factor_map{$germplasm_stock_id},
                $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
            );

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = eval $env_sim_exec->{$env_simulation};
                    $sim_val = (($sim_val - $env_sim_min)/($env_sim_max - $env_sim_min))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env) {
                        $phenotype_min_altered_env = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env) {
                        $phenotype_max_altered_env = $new_val;
                    }

                    $sim_data{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                }
            }
            push @data_matrix_altered_env, \@row;
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }

    print STDERR Dumper [$phenotype_min_altered_env, $phenotype_max_altered_env];

    my ($result_blup_data_altered_env, $result_blup_data_delta_altered_env, $result_blup_spatial_data_altered_env, $result_blup_pe_data_altered_env, $result_blup_pe_data_delta_altered_env, $result_residual_data_altered_env, $result_fitted_data_altered_env, %fixed_effects_altered_env, %rr_genetic_coefficients_altered_env, %rr_temporal_coefficients_altered_env);
    my $model_sum_square_residual_altered_env = 0;
    my $genetic_effect_min_altered_env = 1000000000;
    my $genetic_effect_max_altered_env = -1000000000;
    my $env_effect_min_altered_env = 1000000000;
    my $env_effect_max_altered_env = -1000000000;
    my $genetic_effect_sum_square_altered_env = 0;
    my $genetic_effect_sum_altered_env = 0;
    my $env_effect_sum_square_altered_env = 0;
    my $env_effect_sum_altered_env = 0;
    my $residual_sum_square_altered_env = 0;
    my $residual_sum_altered_env = 0;

    print STDERR "RUN ENV ESTIMATE ON Altered Pheno With Sim Env linear_gradient\n";
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups') {
        # print STDERR Dumper $statistics_cmd;
        eval {
            my $status = system($statistics_cmd);
        };
        my $run_stats_fault = 0;
        if ($@) {
            print STDERR "R ERROR\n";
            print STDERR Dumper $@;
            $run_stats_fault = 1;
        }
        else {
            my $current_gen_row_count = 0;
            my $current_env_row_count = 0;

            open(my $fh, '<', $stats_out_tempfile)
                or die "Could not open file '$stats_out_tempfile' $!";

                print STDERR "Opened $stats_out_tempfile\n";
                my $header = <$fh>;
                my @header_cols;
                if ($csv->parse($header)) {
                    @header_cols = $csv->fields();
                }

                while (my $row = <$fh>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $stock_id = $columns[0];

                        my $stock_name = $stock_info{$stock_id}->{uniquename};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_data_altered_env->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $genetic_effect_min_altered_env) {
                                $genetic_effect_min_altered_env = $value;
                            }
                            elsif ($value >= $genetic_effect_max_altered_env) {
                                $genetic_effect_max_altered_env = $value;
                            }

                            $genetic_effect_sum_altered_env += abs($value);
                            $genetic_effect_sum_square_altered_env = $genetic_effect_sum_square_altered_env + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_gen_row_count++;
                }
            close($fh);

            open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                print STDERR "Opened $stats_out_tempfile_2dspl\n";
                my $header_2dspl = <$fh_2dspl>;
                my @header_cols_2dspl;
                if ($csv->parse($header_2dspl)) {
                    @header_cols_2dspl = $csv->fields();
                }
                shift @header_cols_2dspl;
                while (my $row_2dspl = <$fh_2dspl>) {
                    my @columns;
                    if ($csv->parse($row_2dspl)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols_2dspl) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $plot_id = $columns[0];

                        my $plot_name = $plot_id_map{$plot_id};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_spatial_data_altered_env->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $env_effect_min_altered_env) {
                                $env_effect_min_altered_env = $value;
                            }
                            elsif ($value >= $env_effect_max_altered_env) {
                                $env_effect_max_altered_env = $value;
                            }

                            $env_effect_sum_altered_env += abs($value);
                            $env_effect_sum_square_altered_env = $env_effect_sum_square_altered_env + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_env_row_count++;
                }
            close($fh_2dspl);

            open(my $fh_residual, '<', $stats_out_tempfile_residual)
                or die "Could not open file '$stats_out_tempfile_residual' $!";
            
                print STDERR "Opened $stats_out_tempfile_residual\n";
                my $header_residual = <$fh_residual>;
                my @header_cols_residual;
                if ($csv->parse($header_residual)) {
                    @header_cols_residual = $csv->fields();
                }
                while (my $row = <$fh_residual>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }

                    my $stock_id = $columns[0];
                    foreach (0..$number_traits-1) {
                        my $trait_name = $sorted_trait_names[$_];
                        my $residual = $columns[1 + $_];
                        my $fitted = $columns[1 + $number_traits + $_];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env += abs($residual);
                            $residual_sum_square_altered_env = $residual_sum_square_altered_env + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env = $model_sum_square_residual_altered_env + $residual*$residual;
                    }
                }
            close($fh_residual);

            if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                $run_stats_fault = 1;
            }
        }

        if ($run_stats_fault == 1) {
            $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
            $c->detach();
            print STDERR "ERROR IN R CMD\n";
        }
    }
    elsif ($statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups') {
        my @encoded_traits = values %trait_name_encoder;
        foreach my $t (@encoded_traits) {

            $statistics_cmd = 'R -e "library(sommer); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_file.'\', header=FALSE, sep=\'\t\'));
            geno_mat <- acast(geno_mat_3col, V1~V2, value.var=\'V3\');
            geno_mat[is.na(geno_mat)] <- 0;
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumberFactor);
            mat\$colNumberFactor <- as.factor(mat\$colNumberFactor);
            mix <- mmer('.$t.'~1 + replicate, random=~vs(id, Gu=geno_mat, Gtc=unsm(1)) +vs(rowNumberFactor, Gtc=diag(1)) +vs(colNumberFactor, Gtc=diag(1)) +vs(spl2D(rowNumber, colNumber), Gtc=diag(1)), rcov=~vs(units, Gtc=unsm(1)), data=mat, tolparinv='.$tolparinv.');
            if (!is.null(mix\$U)) {
            #gen_cor <- cov2cor(mix\$sigma\$\`u:id\`);
            write.table(mix\$U\$\`u:id\`, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:rowNumberFactor\`, file=\''.$stats_out_tempfile_row.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:colNumberFactor\`, file=\''.$stats_out_tempfile_col.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mix\$data\$plot_id, residuals = mix\$residuals, fitted = mix\$fitted), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            X <- with(mat, spl2D(rowNumber, colNumber));
            spatial_blup_results <- data.frame(plot_id = mat\$plot_id);
            blups1 <- mix\$U\$\`u:rowNumber\`\$'.$t.';
            spatial_blup_results\$'.$t.' <- data.matrix(X) %*% data.matrix(blups1);
            write.table(spatial_blup_results, file=\''.$stats_out_tempfile_2dspl.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            # print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };
            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;

                open(my $fh, '<', $stats_out_tempfile)
                    or die "Could not open file '$stats_out_tempfile' $!";

                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;
                    my @header_cols;
                    if ($csv->parse($header)) {
                        @header_cols = $csv->fields();
                    }

                    while (my $row = <$fh>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $stock_id = $columns[0];

                                my $stock_name = $stock_info{$stock_id}->{uniquename};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_data_altered_env->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $genetic_effect_min_altered_env) {
                                        $genetic_effect_min_altered_env = $value;
                                    }
                                    elsif ($value >= $genetic_effect_max_altered_env) {
                                        $genetic_effect_max_altered_env = $value;
                                    }

                                    $genetic_effect_sum_altered_env += abs($value);
                                    $genetic_effect_sum_square_altered_env = $genetic_effect_sum_square_altered_env + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_gen_row_count++;
                    }
                close($fh);

                open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                    or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                    print STDERR "Opened $stats_out_tempfile_2dspl\n";
                    my $header_2dspl = <$fh_2dspl>;
                    my @header_cols_2dspl;
                    if ($csv->parse($header_2dspl)) {
                        @header_cols_2dspl = $csv->fields();
                    }
                    shift @header_cols_2dspl;
                    while (my $row_2dspl = <$fh_2dspl>) {
                        my @columns;
                        if ($csv->parse($row_2dspl)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols_2dspl) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $plot_id = $columns[0];

                                my $plot_name = $plot_id_map{$plot_id};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_spatial_data_altered_env->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $env_effect_min_altered_env) {
                                        $env_effect_min_altered_env = $value;
                                    }
                                    elsif ($value >= $env_effect_max_altered_env) {
                                        $env_effect_max_altered_env = $value;
                                    }

                                    $env_effect_sum_altered_env += abs($value);
                                    $env_effect_sum_square_altered_env = $env_effect_sum_square_altered_env + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_env_row_count++;
                    }
                close($fh_2dspl);

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $trait_name = $trait_name_encoder_rev{$t};
                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env += abs($residual);
                            $residual_sum_square_altered_env = $residual_sum_square_altered_env + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env = $model_sum_square_residual_altered_env + $residual*$residual;
                    }
                close($fh_residual);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {

        print STDERR Dumper $statistics_cmd;
        my $status_r = system($statistics_cmd);

        my @pheno_var;
        open(my $fh_r, '<', $stats_out_param_tempfile)
            or die "Could not open file '$stats_out_param_tempfile' $!";
            print STDERR "Opened $stats_out_param_tempfile\n";

            while (my $row = <$fh_r>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                push @pheno_var, \@columns;
            }
        close($fh_r);
        # print STDERR Dumper \@pheno_var;

        my $stats_tempfile_2_basename = basename($stats_tempfile_2);
        my $grm_file_basename = basename($grm_rename_tempfile);
        my $permanent_environment_structure_file_basename = basename($permanent_environment_structure_tempfile);
        my $permanent_environment_structure_env_file_basename = basename($permanent_environment_structure_env_tempfile_mat);
        #my @phenotype_header = ("id", "plot_id", "replicate", "time", "replicate_time", "ind_replicate", @sorted_trait_names, "phenotype");

        my $effect_1_levels = scalar(@rep_time_factors);
        my $effect_grm_levels = scalar(@unique_accession_names);
        my $effect_pe_levels = scalar(@ind_rep_factors);

        my @param_file_rows = (
            'DATAFILE',
            $stats_tempfile_2_basename,
            'NUMBER_OF_TRAITS',
            '1',
            'NUMBER_OF_EFFECTS',
            ($legendre_order_number + 1)*2 + 1,
            'OBSERVATION(S)',
            $legendre_order_number + 1 + 6 + 1,
            'WEIGHT(S)',
            '',
            'EFFECTS: POSITION_IN_DATAFILE NUMBER_OF_LEVELS TYPE_OF_EFFECT',
            '5 '.$effect_1_levels.' cross',
        );
        my $p_counter = 1;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p_counter.' '.$effect_grm_levels.' cov 1';
            $p_counter++;
        }
        my $p2_counter = 1;
        my @hetres_group;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p2_counter.' '.$effect_pe_levels.' cov 6';
            push @hetres_group, 6+$p2_counter;
            $p2_counter++;
        }
        my @random_group1;
        foreach (1..$legendre_order_number+1) {
            push @random_group1, 1+$_;
        }
        my $random_group_string1 = join ' ', @random_group1;
        my @random_group2;
        foreach (1..$legendre_order_number+1) {
            push @random_group2, 1+scalar(@random_group1)+$_;
        }
        my $random_group_string2 = join ' ', @random_group2;
        my $hetres_group_string = join ' ', @hetres_group;
        push @param_file_rows, (
            'RANDOM_RESIDUAL VALUES',
            '1',
            'RANDOM_GROUP',
            $random_group_string1,
            'RANDOM_TYPE',
            'user_file_inv',
            'FILE',
            $grm_file_basename,
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        push @param_file_rows, (
            'RANDOM_GROUP',
            $random_group_string2,
            'RANDOM_TYPE'
        );

        if ($permanent_environment_structure eq 'identity') {
            push @param_file_rows, (
                'diagonal',
                'FILE',
                ''
            );
        }
        elsif ($permanent_environment_structure eq 'env_corr_structure') {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_env_file_basename
            );
        }
        else {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_file_basename
            );
        }

        push @param_file_rows, (
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        my $hetres_pol_string = join ' ', @sorted_scaled_ln_times;
        push @param_file_rows, (
            'OPTION hetres_pos '.$hetres_group_string,
            'OPTION hetres_pol '.$hetres_pol_string,
            'OPTION conv_crit '.$tolparinv,
            'OPTION residual',
        );

        open(my $Fp, ">", $parameter_tempfile) || die "Can't open file ".$parameter_tempfile;
            foreach (@param_file_rows) {
                print $Fp "$_\n";
            }
        close($Fp);

        print STDERR Dumper $cmd_f90;
        my $status = system($cmd_f90);

        open(my $fh_log, '<', $stats_out_tempfile)
            or die "Could not open file '$stats_out_tempfile' $!";

            print STDERR "Opened $stats_out_tempfile\n";
            while (my $row = <$fh_log>) {
                print STDERR $row;
            }
        close($fh_log);

        my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
        my $h_time = $schema->storage->dbh()->prepare($q_time);

        $yhat_residual_tempfile = $tmp_stats_dir."/yhat_residual";
        open(my $fh_yhat_res, '<', $yhat_residual_tempfile)
            or die "Could not open file '$yhat_residual_tempfile' $!";
            print STDERR "Opened $yhat_residual_tempfile\n";

            my $pred_res_counter = 0;
            my $trait_counter = 0;
            while (my $row = <$fh_yhat_res>) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $pred = $vals[0];
                my $residual = $vals[1];
                $model_sum_square_residual_altered_env = $model_sum_square_residual_altered_env + $residual*$residual;

                my $plot_name = $plot_id_count_map_reverse{$pred_res_counter};
                my $time = $time_count_map_reverse{$pred_res_counter};

                if (defined $residual && $residual ne '') {
                    $result_residual_data_altered_env->{$plot_name}->{$seen_times{$time}} = [$residual, $timestamp, $user_name, '', ''];
                    $residual_sum_altered_env += abs($residual);
                    $residual_sum_square_altered_env = $residual_sum_square_altered_env + $residual*$residual;
                }
                if (defined $pred && $pred ne '') {
                    $result_fitted_data_altered_env->{$plot_name}->{$seen_times{$time}} = [$pred, $timestamp, $user_name, '', ''];
                }

                $pred_res_counter++;
            }
        close($fh_yhat_res);

        $blupf90_solutions_tempfile = $tmp_stats_dir."/solutions";
        open(my $fh_sol, '<', $blupf90_solutions_tempfile)
            or die "Could not open file '$blupf90_solutions_tempfile' $!";
            print STDERR "Opened $blupf90_solutions_tempfile\n";

            my $head = <$fh_sol>;
            print STDERR $head;

            my $solution_file_counter = 0;
            my $grm_sol_counter = 0;
            my $grm_sol_trait_counter = 0;
            my $pe_sol_counter = 0;
            my $pe_sol_trait_counter = 0;
            while (defined(my $row = <$fh_sol>)) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $level = $vals[2];
                my $value = $vals[3];
                if ($solution_file_counter < $effect_1_levels) {
                    $fixed_effects_altered_env{$solution_file_counter}->{$level} = $value;
                }
                elsif ($solution_file_counter < $effect_1_levels + $effect_grm_levels*($legendre_order_number+1)) {
                    my $accession_name = $accession_id_factor_map_reverse{$level};
                    if ($grm_sol_counter < $effect_grm_levels-1) {
                        $grm_sol_counter++;
                    }
                    else {
                        $grm_sol_counter = 0;
                        $grm_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_genetic_coefficients_altered_env{$accession_name}}, $value;
                    }
                }
                else {
                    my $plot_name = $plot_id_factor_map_reverse{$level};
                    if ($pe_sol_counter < $effect_pe_levels-1) {
                        $pe_sol_counter++;
                    }
                    else {
                        $pe_sol_counter = 0;
                        $pe_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_temporal_coefficients_altered_env{$plot_name}}, $value;
                    }
                }
                $solution_file_counter++;
            }
        close($fh_sol);

        # print STDERR Dumper \%rr_genetic_coefficients_altered;
        # print STDERR Dumper \%rr_temporal_coefficients_altered;

        open(my $Fgc, ">", $coeff_genetic_tempfile) || die "Can't open file ".$coeff_genetic_tempfile;

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env) {
            my @line = ($accession_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fgc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_blup = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_data_altered_env->{$accession_name}->{$time_term_string_blup} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fgc);

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_data_delta_altered_env->{$accession_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $genetic_effect_min_altered_env) {
                    $genetic_effect_min_altered_env = $value;
                }
                elsif ($value >= $genetic_effect_max_altered_env) {
                    $genetic_effect_max_altered_env = $value;
                }

                $genetic_effect_sum_altered_env += abs($value);
                $genetic_effect_sum_square_altered_env = $genetic_effect_sum_square_altered_env + $value*$value;
            }
        }

        open(my $Fpc, ">", $coeff_pe_tempfile) || die "Can't open file ".$coeff_pe_tempfile;

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env) {
            my @line = ($plot_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fpc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_pe = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_pe_data_altered_env->{$plot_name}->{$time_term_string_pe} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fpc);

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_pe_data_delta_altered_env->{$plot_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $env_effect_min_altered_env) {
                    $env_effect_min_altered_env = $value;
                }
                elsif ($value >= $env_effect_max_altered_env) {
                    $env_effect_max_altered_env = $value;
                }

                $env_effect_sum_altered_env += abs($value);
                $env_effect_sum_square_altered_env = $env_effect_sum_square_altered_env + $value*$value;
            }
        }
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $t (@sorted_trait_names) {

            $statistics_cmd = 'R -e "library(asreml); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile_2.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_rename_tempfile.'\', header=FALSE, sep=\' \'));
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumber);
            mat\$colNumberFactor <- as.factor(mat\$colNumber);
            mat\$id_factor <- as.factor(mat\$id_factor);
            mat <- mat[order(mat\$rowNumber, mat\$colNumber),];
            attr(geno_mat_3col,\'rowNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'colNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'INVERSE\') <- TRUE;
            mix <- asreml(t'.$t.'~1 + replicate, random=~vm(id_factor, geno_mat_3col) + ar1(rowNumberFactor):ar1v(colNumberFactor), residual=~idv(units), data=mat);
            if (!is.null(summary(mix,coef=TRUE)\$coef.random)) {
            write.table(summary(mix,coef=TRUE)\$coef.random, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mat\$plot_id, residuals = mix\$residuals, fitted = mix\$linear.predictors), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };

            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;
                my @row_col_ordered_plots_names;

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        push @row_col_ordered_plots_names, $stock_name;
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env->{$stock_name}->{$t} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env += abs($residual);
                            $residual_sum_square_altered_env = $residual_sum_square_altered_env + $residual*$residual;}
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env->{$stock_name}->{$t} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env = $model_sum_square_residual_altered_env + $residual*$residual;
                    }
                close($fh_residual);

                open(my $fh, '<', $stats_out_tempfile) or die "Could not open file '$stats_out_tempfile' $!";
                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;

                    my $solution_file_counter = 0;
                    while (defined(my $row = <$fh>)) {
                        # print STDERR $row;
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $level = $columns[0];
                        my $value = $columns[1];
                        my $std = $columns[2];
                        my $z_ratio = $columns[3];
                        if (defined $value && $value ne '') {
                            if ($solution_file_counter < $number_accessions) {
                                my $stock_name = $accession_id_factor_map_reverse{$solution_file_counter+1};
                                $result_blup_data_altered_env->{$stock_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $genetic_effect_min_altered_env) {
                                    $genetic_effect_min_altered_env = $value;
                                }
                                elsif ($value >= $genetic_effect_max_altered_env) {
                                    $genetic_effect_max_altered_env = $value;
                                }

                                $genetic_effect_sum_altered_env += abs($value);
                                $genetic_effect_sum_square_altered_env = $genetic_effect_sum_square_altered_env + $value*$value;

                                $current_gen_row_count++;
                            }
                            else {
                                my $plot_name = $row_col_ordered_plots_names[$current_env_row_count-$number_accessions];
                                $result_blup_spatial_data_altered_env->{$plot_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $env_effect_min_altered_env) {
                                    $env_effect_min_altered_env = $value;
                                }
                                elsif ($value >= $env_effect_max_altered_env) {
                                    $env_effect_max_altered_env = $value;
                                }

                                $env_effect_sum_altered_env += abs($value);
                                $env_effect_sum_square_altered_env = $env_effect_sum_square_altered_env + $value*$value;

                                $current_env_row_count++;
                            }
                        }
                        $solution_file_counter++;
                    }
                close($fh);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    print STDERR "ALTERED w/SIM_ENV linear $statistics_select GENETIC EFFECT SUM $genetic_effect_sum_altered_env\n";
    print STDERR "ALTERED w/SIM_ENV linear $statistics_select ENV EFFECT SUM $env_effect_sum_altered_env\n";
    print STDERR Dumper [$genetic_effect_min_altered_env, $genetic_effect_max_altered_env, $env_effect_min_altered_env, $env_effect_max_altered_env];

    $env_simulation = "random_1d_normal_gradient";

    my (%phenotype_data_altered_env_2, @data_matrix_altered_env_2, @data_matrix_phenotypes_altered_env_2);
    my $phenotype_min_altered_env_2 = 1000000000;
    my $phenotype_max_altered_env_2 = -1000000000;
    my $env_sim_min_2 = 10000000000000;
    my $env_sim_max_2 = -10000000000000;
    my %sim_data_2;
    my %sim_data_check_2;

    eval {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $sim_val = eval $env_sim_exec->{$env_simulation};
            $sim_data_check_2{$row_number}->{$col_number} = $sim_val;

            if ($sim_val < $env_sim_min_2) {
                $env_sim_min_2 = $sim_val;
            }
            elsif ($sim_val >= $env_sim_max_2) {
                $env_sim_max_2 = $sim_val;
            }
        }
    };

    if ($permanent_environment_structure eq 'env_corr_structure') {
        my @sim_data_diff_2;
        my $num_plots = scalar(@unique_plot_names);
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $plot_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my $sim_val = $sim_data_check_2{$row_number}->{$col_number};
            my @diffs = ($plot_id, $sim_val);
            foreach my $r (@seen_rows_ordered) {
                foreach my $c (@seen_cols_ordered) {
                    my $v = $sim_data_check_2{$r}->{$c};
                    push @diffs, $sim_val - $v;
                }
            }
            push @sim_data_diff_2, \@diffs;
        }

        open(my $pe_pheno_f, ">", $permanent_environment_structure_env_tempfile) || die "Can't open file ".$permanent_environment_structure_env_tempfile;
            print STDERR "OPENING PERMANENT ENVIRONMENT ENV $env_simulation CORR $permanent_environment_structure_env_tempfile\n";
            foreach (@sim_data_diff_2) {
                my $line = join "\t", @$_;
                print $pe_pheno_f $line."\n";
            }
        close($pe_pheno_f);

        my $pe_rel_cmd = 'R -e "library(lme4); library(data.table);
        mat_agg <- fread(\''.$permanent_environment_structure_env_tempfile.'\', header=FALSE, sep=\'\t\');
        mat_pheno <- mat_agg[,3:ncol(mat_agg)];
        a <- data.matrix(mat_pheno) - (matrix(rep(1,'.$num_plots.'*'.$num_plots.'), nrow='.$num_plots.') %*% data.matrix(mat_pheno))/'.$num_plots.';
        cor_mat <- a %*% t(a);
        rownames(cor_mat) <- data.matrix(mat_agg[,1]);
        colnames(cor_mat) <- data.matrix(mat_agg[,1]);
        range01 <- function(x){(x-min(x))/(max(x)-min(x))};
        cor_mat <- range01(cor_mat);
        write.table(cor_mat, file=\''.$permanent_environment_structure_env_tempfile2.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
        # print STDERR Dumper $pe_rel_cmd;
        my $status_pe_rel = system($pe_rel_cmd);

        my %rel_pe_result_hash;
        open(my $pe_rel_res, '<', $permanent_environment_structure_env_tempfile2) or die "Could not open file '$permanent_environment_structure_env_tempfile2' $!";
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE $permanent_environment_structure_env_tempfile2\n";
            my $header_row = <$pe_rel_res>;
            my @header;
            if ($csv->parse($header_row)) {
                @header = $csv->fields();
            }

            while (my $row = <$pe_rel_res>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                my $stock_id1 = $columns[0];
                my $counter = 1;
                foreach my $stock_id2 (@header) {
                    my $val = $columns[$counter];
                    $rel_pe_result_hash{$stock_id1}->{$stock_id2} = $val;
                    $counter++;
                }
            }
        close($pe_rel_res);

        my $data_rel_pe = '';
        my %result_hash_pe;
        foreach my $s (sort { $a <=> $b } @plot_ids_ordered) {
            foreach my $r (sort { $a <=> $b } @plot_ids_ordered) {
                my $s_factor = $stock_name_row_col{$plot_id_map{$s}}->{plot_id_factor};
                my $r_factor = $stock_name_row_col{$plot_id_map{$r}}->{plot_id_factor};
                if (!exists($result_hash_pe{$s_factor}->{$r_factor}) && !exists($result_hash_pe{$r_factor}->{$s_factor})) {
                    $result_hash_pe{$s_factor}->{$r_factor} = $rel_pe_result_hash{$s}->{$r};
                }
            }
        }
        foreach my $r (sort { $a <=> $b } keys %result_hash_pe) {
            foreach my $s (sort { $a <=> $b } keys %{$result_hash_pe{$r}}) {
                my $val = $result_hash_pe{$r}->{$s};
                if (defined $val and length $val) {
                    $data_rel_pe .= "$r\t$s\t$val\n";
                }
            }
        }

        open(my $pe_rel_out, ">", $permanent_environment_structure_env_tempfile_mat) || die "Can't open file ".$permanent_environment_structure_env_tempfile_mat;
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE 3col $permanent_environment_structure_env_tempfile_mat\n";
            print $pe_rel_out $data_rel_pe;
        close($pe_rel_out);
    }

    print STDERR "ADD SIMULATED ENV TO ALTERED PHENO random_1d_normal_gradient\n";
    print STDERR Dumper [$env_sim_min_2, $env_sim_max_2];
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_genetic_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my @row = ($replicate, $block, "S".$germplasm_stock_id, $obsunit_stock_id, $row_number, $col_number, $row_number, $col_number);

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = eval $env_sim_exec->{$env_simulation};
                    $sim_val = (($sim_val - $env_sim_min_2)/($env_sim_max_2 - $env_sim_min_2))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env_2) {
                        $phenotype_min_altered_env_2 = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env_2) {
                        $phenotype_max_altered_env_2 = $new_val;
                    }

                    $sim_data_2{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env_2{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, 'NA';
                }
            }
            push @data_matrix_altered_env_2, \@row;
        }

        open(my $F, ">", $stats_tempfile) || die "Can't open file ".$stats_tempfile;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env_2) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @data_matrix_phenotypes_row;
            my $current_trait_index = 0;
            foreach my $t (@sorted_trait_names) {
                my @row = (
                    $accession_id_factor_map{$germplasm_stock_id},
                    $obsunit_stock_id,
                    $replicate,
                    $t,
                    $plot_rep_time_factor_map{$obsunit_stock_id}->{$replicate}->{$t},
                    $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
                );

                my $polys = $polynomial_map{$t};
                push @row, @$polys;

                if (defined($phenotype_data_altered{$p}->{$t})) {
                    if ($use_area_under_curve) {
                        my $val = 0;
                        foreach my $counter (0..$current_trait_index) {
                            if ($counter == 0) {
                                $val = $val + $phenotype_data_altered{$p}->{$sorted_trait_names[$counter]} + 0;
                            }
                            else {
                                my $t1 = $sorted_trait_names[$counter-1];
                                my $t2 = $sorted_trait_names[$counter];
                                my $p1 = $phenotype_data_altered{$p}->{$t1} + 0;
                                my $p2 = $phenotype_data_altered{$p}->{$t2} + 0;
                                my $neg = 1;
                                my $min_val = $p1;
                                if ($p2 < $p1) {
                                    $neg = -1;
                                    $min_val = $p2;
                                }
                                $val = $val + (($neg*($p2-$p1)*($t2-$t1))/2)+($t2-$t1)*$min_val;
                            }
                        }

                        my $sim_val = eval $env_sim_exec->{$env_simulation};
                        $sim_val = (($sim_val - $env_sim_min_2)/($env_sim_max_2 - $env_sim_min_2))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env_2) {
                            $phenotype_min_altered_env_2 = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env_2) {
                            $phenotype_max_altered_env_2 = $val;
                        }

                        $sim_data_2{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env_2{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                    else {
                        my $val = $phenotype_data_altered{$p}->{$t} + 0;

                        my $sim_val = eval $env_sim_exec->{$env_simulation};
                        $sim_val = (($sim_val - $env_sim_min_2)/($env_sim_max_2 - $env_sim_min_2))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env_2) {
                            $phenotype_min_altered_env_2 = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env_2) {
                            $phenotype_max_altered_env_2 = $val;
                        }

                        $sim_data_2{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env_2{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                    push @data_matrix_phenotypes_row, 'NA';
                }

                push @data_matrix_altered_env_2, \@row;
                push @data_matrix_phenotypes_altered_env_2, \@data_matrix_phenotypes_row;

                $current_trait_index++;
            }
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            foreach (@data_matrix_altered_env_2) {
                my $line = join ' ', @$_;
                print $F "$line\n";
            }
        close($F);

        open(my $F2, ">", $stats_prep2_tempfile) || die "Can't open file ".$stats_prep2_tempfile;
            foreach (@data_matrix_phenotypes_altered_env_2) {
                my $line = join ',', @$_;
                print $F2 "$line\n";
            }
        close($F2);
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @row = (
                $germplasm_stock_id,
                $obsunit_stock_id,
                $replicate,
                $row_number,
                $col_number,
                $accession_id_factor_map{$germplasm_stock_id},
                $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
            );

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = eval $env_sim_exec->{$env_simulation};
                    $sim_val = (($sim_val - $env_sim_min_2)/($env_sim_max_2 - $env_sim_min_2))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env_2) {
                        $phenotype_min_altered_env_2 = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env_2) {
                        $phenotype_max_altered_env_2 = $new_val;
                    }

                    $sim_data_2{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env_2{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                }
            }
            push @data_matrix_altered_env_2, \@row;
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env_2) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }

    print STDERR Dumper [$phenotype_min_altered_env_2, $phenotype_max_altered_env_2];

    my ($result_blup_data_altered_env_2, $result_blup_data_delta_altered_env_2, $result_blup_spatial_data_altered_env_2, $result_blup_pe_data_altered_env_2, $result_blup_pe_data_delta_altered_env_2, $result_residual_data_altered_env_2, $result_fitted_data_altered_env_2, %fixed_effects_altered_env_2, %rr_genetic_coefficients_altered_env_2, %rr_temporal_coefficients_altered_env_2);
    my $model_sum_square_residual_altered_env_2 = 0;
    my $genetic_effect_min_altered_env_2 = 1000000000;
    my $genetic_effect_max_altered_env_2 = -1000000000;
    my $env_effect_min_altered_env_2 = 1000000000;
    my $env_effect_max_altered_env_2 = -1000000000;
    my $genetic_effect_sum_square_altered_env_2 = 0;
    my $genetic_effect_sum_altered_env_2 = 0;
    my $env_effect_sum_square_altered_env_2 = 0;
    my $env_effect_sum_altered_env_2 = 0;
    my $residual_sum_square_altered_env_2 = 0;
    my $residual_sum_altered_env_2 = 0;

    print STDERR "RUN ENV ESTIMATE ON Altered Pheno With Sim Env random_1d_normal_gradient\n";
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups') {
        # print STDERR Dumper $statistics_cmd;
        eval {
            my $status = system($statistics_cmd);
        };
        my $run_stats_fault = 0;
        if ($@) {
            print STDERR "R ERROR\n";
            print STDERR Dumper $@;
            $run_stats_fault = 1;
        }
        else {
            my $current_gen_row_count = 0;
            my $current_env_row_count = 0;

            open(my $fh, '<', $stats_out_tempfile)
                or die "Could not open file '$stats_out_tempfile' $!";

                print STDERR "Opened $stats_out_tempfile\n";
                my $header = <$fh>;
                my @header_cols;
                if ($csv->parse($header)) {
                    @header_cols = $csv->fields();
                }

                while (my $row = <$fh>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $stock_id = $columns[0];

                        my $stock_name = $stock_info{$stock_id}->{uniquename};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_data_altered_env_2->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $genetic_effect_min_altered_env_2) {
                                $genetic_effect_min_altered_env_2 = $value;
                            }
                            elsif ($value >= $genetic_effect_max_altered_env_2) {
                                $genetic_effect_max_altered_env_2 = $value;
                            }

                            $genetic_effect_sum_altered_env_2 += abs($value);
                            $genetic_effect_sum_square_altered_env_2 = $genetic_effect_sum_square_altered_env_2 + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_gen_row_count++;
                }
            close($fh);

            open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                print STDERR "Opened $stats_out_tempfile_2dspl\n";
                my $header_2dspl = <$fh_2dspl>;
                my @header_cols_2dspl;
                if ($csv->parse($header_2dspl)) {
                    @header_cols_2dspl = $csv->fields();
                }
                shift @header_cols_2dspl;
                while (my $row_2dspl = <$fh_2dspl>) {
                    my @columns;
                    if ($csv->parse($row_2dspl)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols_2dspl) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $plot_id = $columns[0];

                        my $plot_name = $plot_id_map{$plot_id};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_spatial_data_altered_env_2->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $env_effect_min_altered_env_2) {
                                $env_effect_min_altered_env_2 = $value;
                            }
                            elsif ($value >= $env_effect_max_altered_env_2) {
                                $env_effect_max_altered_env_2 = $value;
                            }

                            $env_effect_sum_altered_env_2 += abs($value);
                            $env_effect_sum_square_altered_env_2 = $env_effect_sum_square_altered_env_2 + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_env_row_count++;
                }
            close($fh_2dspl);

            open(my $fh_residual, '<', $stats_out_tempfile_residual)
                or die "Could not open file '$stats_out_tempfile_residual' $!";
            
                print STDERR "Opened $stats_out_tempfile_residual\n";
                my $header_residual = <$fh_residual>;
                my @header_cols_residual;
                if ($csv->parse($header_residual)) {
                    @header_cols_residual = $csv->fields();
                }
                while (my $row = <$fh_residual>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }

                    my $stock_id = $columns[0];
                    foreach (0..$number_traits-1) {
                        my $trait_name = $sorted_trait_names[$_];
                        my $residual = $columns[1 + $_];
                        my $fitted = $columns[1 + $number_traits + $_];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_2->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_2 += abs($residual);
                            $residual_sum_square_altered_env_2 = $residual_sum_square_altered_env_2 + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_2->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_2 = $model_sum_square_residual_altered_env_2 + $residual*$residual;
                    }
                }
            close($fh_residual);

            if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                $run_stats_fault = 1;
            }
        }

        if ($run_stats_fault == 1) {
            $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
            $c->detach();
            print STDERR "ERROR IN R CMD\n";
        }
    }
    elsif ($statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups') {
        my @encoded_traits = values %trait_name_encoder;
        foreach my $t (@encoded_traits) {

            $statistics_cmd = 'R -e "library(sommer); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_file.'\', header=FALSE, sep=\'\t\'));
            geno_mat <- acast(geno_mat_3col, V1~V2, value.var=\'V3\');
            geno_mat[is.na(geno_mat)] <- 0;
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumberFactor);
            mat\$colNumberFactor <- as.factor(mat\$colNumberFactor);
            mix <- mmer('.$t.'~1 + replicate, random=~vs(id, Gu=geno_mat, Gtc=unsm(1)) +vs(rowNumberFactor, Gtc=diag(1)) +vs(colNumberFactor, Gtc=diag(1)) +vs(spl2D(rowNumber, colNumber), Gtc=diag(1)), rcov=~vs(units, Gtc=unsm(1)), data=mat, tolparinv='.$tolparinv.');
            if (!is.null(mix\$U)) {
            #gen_cor <- cov2cor(mix\$sigma\$\`u:id\`);
            write.table(mix\$U\$\`u:id\`, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:rowNumberFactor\`, file=\''.$stats_out_tempfile_row.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:colNumberFactor\`, file=\''.$stats_out_tempfile_col.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mix\$data\$plot_id, residuals = mix\$residuals, fitted = mix\$fitted), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            X <- with(mat, spl2D(rowNumber, colNumber));
            spatial_blup_results <- data.frame(plot_id = mat\$plot_id);
            blups1 <- mix\$U\$\`u:rowNumber\`\$'.$t.';
            spatial_blup_results\$'.$t.' <- data.matrix(X) %*% data.matrix(blups1);
            write.table(spatial_blup_results, file=\''.$stats_out_tempfile_2dspl.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            # print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };
            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;

                open(my $fh, '<', $stats_out_tempfile)
                    or die "Could not open file '$stats_out_tempfile' $!";

                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;
                    my @header_cols;
                    if ($csv->parse($header)) {
                        @header_cols = $csv->fields();
                    }

                    while (my $row = <$fh>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $stock_id = $columns[0];

                                my $stock_name = $stock_info{$stock_id}->{uniquename};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_data_altered_env_2->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $genetic_effect_min_altered_env_2) {
                                        $genetic_effect_min_altered_env_2 = $value;
                                    }
                                    elsif ($value >= $genetic_effect_max_altered_env_2) {
                                        $genetic_effect_max_altered_env_2 = $value;
                                    }

                                    $genetic_effect_sum_altered_env_2 += abs($value);
                                    $genetic_effect_sum_square_altered_env_2 = $genetic_effect_sum_square_altered_env_2 + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_gen_row_count++;
                    }
                close($fh);

                open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                    or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                    print STDERR "Opened $stats_out_tempfile_2dspl\n";
                    my $header_2dspl = <$fh_2dspl>;
                    my @header_cols_2dspl;
                    if ($csv->parse($header_2dspl)) {
                        @header_cols_2dspl = $csv->fields();
                    }
                    shift @header_cols_2dspl;
                    while (my $row_2dspl = <$fh_2dspl>) {
                        my @columns;
                        if ($csv->parse($row_2dspl)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols_2dspl) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $plot_id = $columns[0];

                                my $plot_name = $plot_id_map{$plot_id};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_spatial_data_altered_env_2->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $env_effect_min_altered_env_2) {
                                        $env_effect_min_altered_env_2 = $value;
                                    }
                                    elsif ($value >= $env_effect_max_altered_env_2) {
                                        $env_effect_max_altered_env_2 = $value;
                                    }

                                    $env_effect_sum_altered_env_2 += abs($value);
                                    $env_effect_sum_square_altered_env_2 = $env_effect_sum_square_altered_env_2 + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_env_row_count++;
                    }
                close($fh_2dspl);

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $trait_name = $trait_name_encoder_rev{$t};
                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_2->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_2 += abs($residual);
                            $residual_sum_square_altered_env_2 = $residual_sum_square_altered_env_2 + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_2->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_2 = $model_sum_square_residual_altered_env_2 + $residual*$residual;
                    }
                close($fh_residual);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {

        print STDERR Dumper $statistics_cmd;
        my $status_r = system($statistics_cmd);

        my @pheno_var;
        open(my $fh_r, '<', $stats_out_param_tempfile)
            or die "Could not open file '$stats_out_param_tempfile' $!";
            print STDERR "Opened $stats_out_param_tempfile\n";

            while (my $row = <$fh_r>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                push @pheno_var, \@columns;
            }
        close($fh_r);
        # print STDERR Dumper \@pheno_var;

        my $stats_tempfile_2_basename = basename($stats_tempfile_2);
        my $grm_file_basename = basename($grm_rename_tempfile);
        my $permanent_environment_structure_file_basename = basename($permanent_environment_structure_tempfile);
        my $permanent_environment_structure_env_file_basename = basename($permanent_environment_structure_env_tempfile_mat);
        #my @phenotype_header = ("id", "plot_id", "replicate", "time", "replicate_time", "ind_replicate", @sorted_trait_names, "phenotype");

        my $effect_1_levels = scalar(@rep_time_factors);
        my $effect_grm_levels = scalar(@unique_accession_names);
        my $effect_pe_levels = scalar(@ind_rep_factors);

        my @param_file_rows = (
            'DATAFILE',
            $stats_tempfile_2_basename,
            'NUMBER_OF_TRAITS',
            '1',
            'NUMBER_OF_EFFECTS',
            ($legendre_order_number + 1)*2 + 1,
            'OBSERVATION(S)',
            $legendre_order_number + 1 + 6 + 1,
            'WEIGHT(S)',
            '',
            'EFFECTS: POSITION_IN_DATAFILE NUMBER_OF_LEVELS TYPE_OF_EFFECT',
            '5 '.$effect_1_levels.' cross',
        );
        my $p_counter = 1;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p_counter.' '.$effect_grm_levels.' cov 1';
            $p_counter++;
        }
        my $p2_counter = 1;
        my @hetres_group;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p2_counter.' '.$effect_pe_levels.' cov 6';
            push @hetres_group, 6+$p2_counter;
            $p2_counter++;
        }
        my @random_group1;
        foreach (1..$legendre_order_number+1) {
            push @random_group1, 1+$_;
        }
        my $random_group_string1 = join ' ', @random_group1;
        my @random_group2;
        foreach (1..$legendre_order_number+1) {
            push @random_group2, 1+scalar(@random_group1)+$_;
        }
        my $random_group_string2 = join ' ', @random_group2;
        my $hetres_group_string = join ' ', @hetres_group;
        push @param_file_rows, (
            'RANDOM_RESIDUAL VALUES',
            '1',
            'RANDOM_GROUP',
            $random_group_string1,
            'RANDOM_TYPE',
            'user_file_inv',
            'FILE',
            $grm_file_basename,
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        push @param_file_rows, (
            'RANDOM_GROUP',
            $random_group_string2,
            'RANDOM_TYPE'
        );

        if ($permanent_environment_structure eq 'identity') {
            push @param_file_rows, (
                'diagonal',
                'FILE',
                ''
            );
        }
        elsif ($permanent_environment_structure eq 'env_corr_structure') {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_env_file_basename
            );
        }
        else {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_file_basename
            );
        }

        push @param_file_rows, (
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        my $hetres_pol_string = join ' ', @sorted_scaled_ln_times;
        push @param_file_rows, (
            'OPTION hetres_pos '.$hetres_group_string,
            'OPTION hetres_pol '.$hetres_pol_string,
            'OPTION conv_crit '.$tolparinv,
            'OPTION residual',
        );

        open(my $Fp, ">", $parameter_tempfile) || die "Can't open file ".$parameter_tempfile;
            foreach (@param_file_rows) {
                print $Fp "$_\n";
            }
        close($Fp);

        print STDERR Dumper $cmd_f90;
        my $status = system($cmd_f90);

        open(my $fh_log, '<', $stats_out_tempfile)
            or die "Could not open file '$stats_out_tempfile' $!";

            print STDERR "Opened $stats_out_tempfile\n";
            while (my $row = <$fh_log>) {
                print STDERR $row;
            }
        close($fh_log);

        my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
        my $h_time = $schema->storage->dbh()->prepare($q_time);

        $yhat_residual_tempfile = $tmp_stats_dir."/yhat_residual";
        open(my $fh_yhat_res, '<', $yhat_residual_tempfile)
            or die "Could not open file '$yhat_residual_tempfile' $!";
            print STDERR "Opened $yhat_residual_tempfile\n";

            my $pred_res_counter = 0;
            my $trait_counter = 0;
            while (my $row = <$fh_yhat_res>) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $pred = $vals[0];
                my $residual = $vals[1];
                $model_sum_square_residual_altered_env_2 = $model_sum_square_residual_altered_env_2 + $residual*$residual;

                my $plot_name = $plot_id_count_map_reverse{$pred_res_counter};
                my $time = $time_count_map_reverse{$pred_res_counter};

                if (defined $residual && $residual ne '') {
                    $result_residual_data_altered_env_2->{$plot_name}->{$seen_times{$time}} = [$residual, $timestamp, $user_name, '', ''];
                    $residual_sum_altered_env_2 += abs($residual);
                    $residual_sum_square_altered_env_2 = $residual_sum_square_altered_env_2 + $residual*$residual;
                }
                if (defined $pred && $pred ne '') {
                    $result_fitted_data_altered_env_2->{$plot_name}->{$seen_times{$time}} = [$pred, $timestamp, $user_name, '', ''];
                }

                $pred_res_counter++;
            }
        close($fh_yhat_res);

        $blupf90_solutions_tempfile = $tmp_stats_dir."/solutions";
        open(my $fh_sol, '<', $blupf90_solutions_tempfile)
            or die "Could not open file '$blupf90_solutions_tempfile' $!";
            print STDERR "Opened $blupf90_solutions_tempfile\n";

            my $head = <$fh_sol>;
            print STDERR $head;

            my $solution_file_counter = 0;
            my $grm_sol_counter = 0;
            my $grm_sol_trait_counter = 0;
            my $pe_sol_counter = 0;
            my $pe_sol_trait_counter = 0;
            while (defined(my $row = <$fh_sol>)) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $level = $vals[2];
                my $value = $vals[3];
                if ($solution_file_counter < $effect_1_levels) {
                    $fixed_effects_altered_env_2{$solution_file_counter}->{$level} = $value;
                }
                elsif ($solution_file_counter < $effect_1_levels + $effect_grm_levels*($legendre_order_number+1)) {
                    my $accession_name = $accession_id_factor_map_reverse{$level};
                    if ($grm_sol_counter < $effect_grm_levels-1) {
                        $grm_sol_counter++;
                    }
                    else {
                        $grm_sol_counter = 0;
                        $grm_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_genetic_coefficients_altered_env_2{$accession_name}}, $value;
                    }
                }
                else {
                    my $plot_name = $plot_id_factor_map_reverse{$level};
                    if ($pe_sol_counter < $effect_pe_levels-1) {
                        $pe_sol_counter++;
                    }
                    else {
                        $pe_sol_counter = 0;
                        $pe_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_temporal_coefficients_altered_env_2{$plot_name}}, $value;
                    }
                }
                $solution_file_counter++;
            }
        close($fh_sol);

        # print STDERR Dumper \%rr_genetic_coefficients_altered;
        # print STDERR Dumper \%rr_temporal_coefficients_altered;

        open(my $Fgc, ">", $coeff_genetic_tempfile) || die "Can't open file ".$coeff_genetic_tempfile;

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env_2) {
            my @line = ($accession_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fgc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_blup = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_data_altered_env_2->{$accession_name}->{$time_term_string_blup} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fgc);

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env_2) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_data_delta_altered_env_2->{$accession_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $genetic_effect_min_altered_env_2) {
                    $genetic_effect_min_altered_env_2 = $value;
                }
                elsif ($value >= $genetic_effect_max_altered_env_2) {
                    $genetic_effect_max_altered_env_2 = $value;
                }

                $genetic_effect_sum_altered_env_2 += abs($value);
                $genetic_effect_sum_square_altered_env_2 = $genetic_effect_sum_square_altered_env_2 + $value*$value;
            }
        }

        open(my $Fpc, ">", $coeff_pe_tempfile) || die "Can't open file ".$coeff_pe_tempfile;

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env_2) {
            my @line = ($plot_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fpc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_pe = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_pe_data_altered_env_2->{$plot_name}->{$time_term_string_pe} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fpc);

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env_2) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_pe_data_delta_altered_env_2->{$plot_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $env_effect_min_altered_env_2) {
                    $env_effect_min_altered_env_2 = $value;
                }
                elsif ($value >= $env_effect_max_altered_env_2) {
                    $env_effect_max_altered_env_2 = $value;
                }

                $env_effect_sum_altered_env_2 += abs($value);
                $env_effect_sum_square_altered_env_2 = $env_effect_sum_square_altered_env_2 + $value*$value;
            }
        }
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $t (@sorted_trait_names) {

            $statistics_cmd = 'R -e "library(asreml); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile_2.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_rename_tempfile.'\', header=FALSE, sep=\' \'));
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumber);
            mat\$colNumberFactor <- as.factor(mat\$colNumber);
            mat\$id_factor <- as.factor(mat\$id_factor);
            mat <- mat[order(mat\$rowNumber, mat\$colNumber),];
            attr(geno_mat_3col,\'rowNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'colNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'INVERSE\') <- TRUE;
            mix <- asreml(t'.$t.'~1 + replicate, random=~vm(id_factor, geno_mat_3col) + ar1(rowNumberFactor):ar1v(colNumberFactor), residual=~idv(units), data=mat);
            if (!is.null(summary(mix,coef=TRUE)\$coef.random)) {
            write.table(summary(mix,coef=TRUE)\$coef.random, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mat\$plot_id, residuals = mix\$residuals, fitted = mix\$linear.predictors), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };

            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;
                my @row_col_ordered_plots_names;

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        push @row_col_ordered_plots_names, $stock_name;
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_2->{$stock_name}->{$t} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_2 += abs($residual);
                            $residual_sum_square_altered_env_2 = $residual_sum_square_altered_env_2 + $residual*$residual;}
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_2->{$stock_name}->{$t} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_2 = $model_sum_square_residual_altered_env_2 + $residual*$residual;
                    }
                close($fh_residual);

                open(my $fh, '<', $stats_out_tempfile) or die "Could not open file '$stats_out_tempfile' $!";
                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;

                    my $solution_file_counter = 0;
                    while (defined(my $row = <$fh>)) {
                        # print STDERR $row;
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $level = $columns[0];
                        my $value = $columns[1];
                        my $std = $columns[2];
                        my $z_ratio = $columns[3];
                        if (defined $value && $value ne '') {
                            if ($solution_file_counter < $number_accessions) {
                                my $stock_name = $accession_id_factor_map_reverse{$solution_file_counter+1};
                                $result_blup_data_altered_env_2->{$stock_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $genetic_effect_min_altered_env_2) {
                                    $genetic_effect_min_altered_env_2 = $value;
                                }
                                elsif ($value >= $genetic_effect_max_altered_env_2) {
                                    $genetic_effect_max_altered_env_2 = $value;
                                }

                                $genetic_effect_sum_altered_env_2 += abs($value);
                                $genetic_effect_sum_square_altered_env_2 = $genetic_effect_sum_square_altered_env_2 + $value*$value;

                                $current_gen_row_count++;
                            }
                            else {
                                my $plot_name = $row_col_ordered_plots_names[$current_env_row_count-$number_accessions];
                                $result_blup_spatial_data_altered_env_2->{$plot_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $env_effect_min_altered_env_2) {
                                    $env_effect_min_altered_env_2 = $value;
                                }
                                elsif ($value >= $env_effect_max_altered_env_2) {
                                    $env_effect_max_altered_env_2 = $value;
                                }

                                $env_effect_sum_altered_env_2 += abs($value);
                                $env_effect_sum_square_altered_env_2 = $env_effect_sum_square_altered_env_2 + $value*$value;

                                $current_env_row_count++;
                            }
                        }
                        $solution_file_counter++;
                    }
                close($fh);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    print STDERR "ALTERED w/SIM_ENV 1dn $statistics_select GENETIC EFFECT SUM $genetic_effect_sum_altered_env_2\n";
    print STDERR "ALTERED w/SIM_ENV 1dn $statistics_select ENV EFFECT SUM $env_effect_sum_altered_env_2\n";
    print STDERR Dumper [$genetic_effect_min_altered_env_2, $genetic_effect_max_altered_env_2, $env_effect_min_altered_env_2, $env_effect_max_altered_env_2];

    $env_simulation = "random_2d_normal_gradient";

    my (%phenotype_data_altered_env_3, @data_matrix_altered_env_3, @data_matrix_phenotypes_altered_env_3);
    my $phenotype_min_altered_env_3 = 1000000000;
    my $phenotype_max_altered_env_3 = -1000000000;
    my $env_sim_min_3 = 10000000000000;
    my $env_sim_max_3 = -10000000000000;
    my %sim_data_3;
    my %sim_data_check_3;

    eval {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $sim_val = eval $env_sim_exec->{$env_simulation};
            $sim_data_check_3{$row_number}->{$col_number} = $sim_val;

            if ($sim_val < $env_sim_min_3) {
                $env_sim_min_3 = $sim_val;
            }
            elsif ($sim_val >= $env_sim_max_3) {
                $env_sim_max_3 = $sim_val;
            }
        }
    };

    if ($permanent_environment_structure eq 'env_corr_structure') {
        my @sim_data_diff_3;
        my $num_plots = scalar(@unique_plot_names);
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $plot_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my $sim_val = $sim_data_check_3{$row_number}->{$col_number};
            my @diffs = ($plot_id, $sim_val);
            foreach my $r (@seen_rows_ordered) {
                foreach my $c (@seen_cols_ordered) {
                    my $v = $sim_data_check_3{$r}->{$c};
                    push @diffs, $sim_val - $v;
                }
            }
            push @sim_data_diff_3, \@diffs;
        }

        open(my $pe_pheno_f, ">", $permanent_environment_structure_env_tempfile) || die "Can't open file ".$permanent_environment_structure_env_tempfile;
            print STDERR "OPENING PERMANENT ENVIRONMENT ENV $env_simulation CORR $permanent_environment_structure_env_tempfile\n";
            foreach (@sim_data_diff_3) {
                my $line = join "\t", @$_;
                print $pe_pheno_f $line."\n";
            }
        close($pe_pheno_f);

        my $pe_rel_cmd = 'R -e "library(lme4); library(data.table);
        mat_agg <- fread(\''.$permanent_environment_structure_env_tempfile.'\', header=FALSE, sep=\'\t\');
        mat_pheno <- mat_agg[,3:ncol(mat_agg)];
        a <- data.matrix(mat_pheno) - (matrix(rep(1,'.$num_plots.'*'.$num_plots.'), nrow='.$num_plots.') %*% data.matrix(mat_pheno))/'.$num_plots.';
        cor_mat <- a %*% t(a);
        rownames(cor_mat) <- data.matrix(mat_agg[,1]);
        colnames(cor_mat) <- data.matrix(mat_agg[,1]);
        range01 <- function(x){(x-min(x))/(max(x)-min(x))};
        cor_mat <- range01(cor_mat);
        write.table(cor_mat, file=\''.$permanent_environment_structure_env_tempfile2.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
        # print STDERR Dumper $pe_rel_cmd;
        my $status_pe_rel = system($pe_rel_cmd);

        my %rel_pe_result_hash;
        open(my $pe_rel_res, '<', $permanent_environment_structure_env_tempfile2) or die "Could not open file '$permanent_environment_structure_env_tempfile2' $!";
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE $permanent_environment_structure_env_tempfile2\n";
            my $header_row = <$pe_rel_res>;
            my @header;
            if ($csv->parse($header_row)) {
                @header = $csv->fields();
            }

            while (my $row = <$pe_rel_res>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                my $stock_id1 = $columns[0];
                my $counter = 1;
                foreach my $stock_id2 (@header) {
                    my $val = $columns[$counter];
                    $rel_pe_result_hash{$stock_id1}->{$stock_id2} = $val;
                    $counter++;
                }
            }
        close($pe_rel_res);

        my $data_rel_pe = '';
        my %result_hash_pe;
        foreach my $s (sort { $a <=> $b } @plot_ids_ordered) {
            foreach my $r (sort { $a <=> $b } @plot_ids_ordered) {
                my $s_factor = $stock_name_row_col{$plot_id_map{$s}}->{plot_id_factor};
                my $r_factor = $stock_name_row_col{$plot_id_map{$r}}->{plot_id_factor};
                if (!exists($result_hash_pe{$s_factor}->{$r_factor}) && !exists($result_hash_pe{$r_factor}->{$s_factor})) {
                    $result_hash_pe{$s_factor}->{$r_factor} = $rel_pe_result_hash{$s}->{$r};
                }
            }
        }
        foreach my $r (sort { $a <=> $b } keys %result_hash_pe) {
            foreach my $s (sort { $a <=> $b } keys %{$result_hash_pe{$r}}) {
                my $val = $result_hash_pe{$r}->{$s};
                if (defined $val and length $val) {
                    $data_rel_pe .= "$r\t$s\t$val\n";
                }
            }
        }

        open(my $pe_rel_out, ">", $permanent_environment_structure_env_tempfile_mat) || die "Can't open file ".$permanent_environment_structure_env_tempfile_mat;
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE 3col $permanent_environment_structure_env_tempfile_mat\n";
            print $pe_rel_out $data_rel_pe;
        close($pe_rel_out);
    }

    print STDERR "ADD SIMULATED ENV TO ALTERED PHENO random_2d_normal_gradient\n";
    print STDERR Dumper [$env_sim_min_3, $env_sim_max_3];
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_genetic_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my @row = ($replicate, $block, "S".$germplasm_stock_id, $obsunit_stock_id, $row_number, $col_number, $row_number, $col_number);

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = eval $env_sim_exec->{$env_simulation};
                    $sim_val = (($sim_val - $env_sim_min_3)/($env_sim_max_3 - $env_sim_min_3))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env_3) {
                        $phenotype_min_altered_env_3 = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env_3) {
                        $phenotype_max_altered_env_3 = $new_val;
                    }

                    $sim_data_3{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env_3{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, 'NA';
                }
            }
            push @data_matrix_altered_env_3, \@row;
        }

        open(my $F, ">", $stats_tempfile) || die "Can't open file ".$stats_tempfile;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env_3) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @data_matrix_phenotypes_row;
            my $current_trait_index = 0;
            foreach my $t (@sorted_trait_names) {
                my @row = (
                    $accession_id_factor_map{$germplasm_stock_id},
                    $obsunit_stock_id,
                    $replicate,
                    $t,
                    $plot_rep_time_factor_map{$obsunit_stock_id}->{$replicate}->{$t},
                    $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
                );

                my $polys = $polynomial_map{$t};
                push @row, @$polys;

                if (defined($phenotype_data_altered{$p}->{$t})) {
                    if ($use_area_under_curve) {
                        my $val = 0;
                        foreach my $counter (0..$current_trait_index) {
                            if ($counter == 0) {
                                $val = $val + $phenotype_data_altered{$p}->{$sorted_trait_names[$counter]} + 0;
                            }
                            else {
                                my $t1 = $sorted_trait_names[$counter-1];
                                my $t2 = $sorted_trait_names[$counter];
                                my $p1 = $phenotype_data_altered{$p}->{$t1} + 0;
                                my $p2 = $phenotype_data_altered{$p}->{$t2} + 0;
                                my $neg = 1;
                                my $min_val = $p1;
                                if ($p2 < $p1) {
                                    $neg = -1;
                                    $min_val = $p2;
                                }
                                $val = $val + (($neg*($p2-$p1)*($t2-$t1))/2)+($t2-$t1)*$min_val;
                            }
                        }

                        my $sim_val = eval $env_sim_exec->{$env_simulation};
                        $sim_val = (($sim_val - $env_sim_min_3)/($env_sim_max_3 - $env_sim_min_3))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env_3) {
                            $phenotype_min_altered_env_3 = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env_3) {
                            $phenotype_max_altered_env_3 = $val;
                        }

                        $sim_data_3{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env_3{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                    else {
                        my $val = $phenotype_data_altered{$p}->{$t} + 0;

                        my $sim_val = eval $env_sim_exec->{$env_simulation};
                        $sim_val = (($sim_val - $env_sim_min_3)/($env_sim_max_3 - $env_sim_min_3))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env_3) {
                            $phenotype_min_altered_env_3 = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env_3) {
                            $phenotype_max_altered_env_3 = $val;
                        }

                        $sim_data_3{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env_3{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                    push @data_matrix_phenotypes_row, 'NA';
                }

                push @data_matrix_altered_env_3, \@row;
                push @data_matrix_phenotypes_altered_env_3, \@data_matrix_phenotypes_row;

                $current_trait_index++;
            }
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            foreach (@data_matrix_altered_env_3) {
                my $line = join ' ', @$_;
                print $F "$line\n";
            }
        close($F);

        open(my $F2, ">", $stats_prep2_tempfile) || die "Can't open file ".$stats_prep2_tempfile;
            foreach (@data_matrix_phenotypes_altered_env_3) {
                my $line = join ',', @$_;
                print $F2 "$line\n";
            }
        close($F2);
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @row = (
                $germplasm_stock_id,
                $obsunit_stock_id,
                $replicate,
                $row_number,
                $col_number,
                $accession_id_factor_map{$germplasm_stock_id},
                $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
            );

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = eval $env_sim_exec->{$env_simulation};
                    $sim_val = (($sim_val - $env_sim_min_3)/($env_sim_max_3 - $env_sim_min_3))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env_3) {
                        $phenotype_min_altered_env_3 = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env_3) {
                        $phenotype_max_altered_env_3 = $new_val;
                    }

                    $sim_data_3{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env_3{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                }
            }
            push @data_matrix_altered_env_3, \@row;
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env_3) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }

    print STDERR Dumper [$phenotype_min_altered_env_3, $phenotype_max_altered_env_3];

    my ($result_blup_data_altered_env_3, $result_blup_data_delta_altered_env_3, $result_blup_spatial_data_altered_env_3, $result_blup_pe_data_altered_env_3, $result_blup_pe_data_delta_altered_env_3, $result_residual_data_altered_env_3, $result_fitted_data_altered_env_3, %fixed_effects_altered_env_3, %rr_genetic_coefficients_altered_env_3, %rr_temporal_coefficients_altered_env_3);
    my $model_sum_square_residual_altered_env_3 = 0;
    my $genetic_effect_min_altered_env_3 = 1000000000;
    my $genetic_effect_max_altered_env_3 = -1000000000;
    my $env_effect_min_altered_env_3 = 1000000000;
    my $env_effect_max_altered_env_3 = -1000000000;
    my $genetic_effect_sum_square_altered_env_3 = 0;
    my $genetic_effect_sum_altered_env_3 = 0;
    my $env_effect_sum_square_altered_env_3 = 0;
    my $env_effect_sum_altered_env_3 = 0;
    my $residual_sum_square_altered_env_3 = 0;
    my $residual_sum_altered_env_3 = 0;

    print STDERR "RUN ENV ESTIMATE ON Altered Pheno With Sim Env random_2d_normal_gradient\n";
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups') {
        # print STDERR Dumper $statistics_cmd;
        eval {
            my $status = system($statistics_cmd);
        };
        my $run_stats_fault = 0;
        if ($@) {
            print STDERR "R ERROR\n";
            print STDERR Dumper $@;
            $run_stats_fault = 1;
        }
        else {
            my $current_gen_row_count = 0;
            my $current_env_row_count = 0;

            open(my $fh, '<', $stats_out_tempfile)
                or die "Could not open file '$stats_out_tempfile' $!";

                print STDERR "Opened $stats_out_tempfile\n";
                my $header = <$fh>;
                my @header_cols;
                if ($csv->parse($header)) {
                    @header_cols = $csv->fields();
                }

                while (my $row = <$fh>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $stock_id = $columns[0];

                        my $stock_name = $stock_info{$stock_id}->{uniquename};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_data_altered_env_3->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $genetic_effect_min_altered_env_3) {
                                $genetic_effect_min_altered_env_3 = $value;
                            }
                            elsif ($value >= $genetic_effect_max_altered_env_3) {
                                $genetic_effect_max_altered_env_3 = $value;
                            }

                            $genetic_effect_sum_altered_env_3 += abs($value);
                            $genetic_effect_sum_square_altered_env_3 = $genetic_effect_sum_square_altered_env_3 + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_gen_row_count++;
                }
            close($fh);

            open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                print STDERR "Opened $stats_out_tempfile_2dspl\n";
                my $header_2dspl = <$fh_2dspl>;
                my @header_cols_2dspl;
                if ($csv->parse($header_2dspl)) {
                    @header_cols_2dspl = $csv->fields();
                }
                shift @header_cols_2dspl;
                while (my $row_2dspl = <$fh_2dspl>) {
                    my @columns;
                    if ($csv->parse($row_2dspl)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols_2dspl) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $plot_id = $columns[0];

                        my $plot_name = $plot_id_map{$plot_id};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_spatial_data_altered_env_3->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $env_effect_min_altered_env_3) {
                                $env_effect_min_altered_env_3 = $value;
                            }
                            elsif ($value >= $env_effect_max_altered_env_3) {
                                $env_effect_max_altered_env_3 = $value;
                            }

                            $env_effect_sum_altered_env_3 += abs($value);
                            $env_effect_sum_square_altered_env_3 = $env_effect_sum_square_altered_env_3 + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_env_row_count++;
                }
            close($fh_2dspl);

            open(my $fh_residual, '<', $stats_out_tempfile_residual)
                or die "Could not open file '$stats_out_tempfile_residual' $!";
            
                print STDERR "Opened $stats_out_tempfile_residual\n";
                my $header_residual = <$fh_residual>;
                my @header_cols_residual;
                if ($csv->parse($header_residual)) {
                    @header_cols_residual = $csv->fields();
                }
                while (my $row = <$fh_residual>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }

                    my $stock_id = $columns[0];
                    foreach (0..$number_traits-1) {
                        my $trait_name = $sorted_trait_names[$_];
                        my $residual = $columns[1 + $_];
                        my $fitted = $columns[1 + $number_traits + $_];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_3->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_3 += abs($residual);
                            $residual_sum_square_altered_env_3 = $residual_sum_square_altered_env_3 + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_3->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_3 = $model_sum_square_residual_altered_env_3 + $residual*$residual;
                    }
                }
            close($fh_residual);

            if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                $run_stats_fault = 1;
            }
        }

        if ($run_stats_fault == 1) {
            $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
            $c->detach();
            print STDERR "ERROR IN R CMD\n";
        }
    }
    elsif ($statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups') {
        my @encoded_traits = values %trait_name_encoder;
        foreach my $t (@encoded_traits) {

            $statistics_cmd = 'R -e "library(sommer); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_file.'\', header=FALSE, sep=\'\t\'));
            geno_mat <- acast(geno_mat_3col, V1~V2, value.var=\'V3\');
            geno_mat[is.na(geno_mat)] <- 0;
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumberFactor);
            mat\$colNumberFactor <- as.factor(mat\$colNumberFactor);
            mix <- mmer('.$t.'~1 + replicate, random=~vs(id, Gu=geno_mat, Gtc=unsm(1)) +vs(rowNumberFactor, Gtc=diag(1)) +vs(colNumberFactor, Gtc=diag(1)) +vs(spl2D(rowNumber, colNumber), Gtc=diag(1)), rcov=~vs(units, Gtc=unsm(1)), data=mat, tolparinv='.$tolparinv.');
            if (!is.null(mix\$U)) {
            #gen_cor <- cov2cor(mix\$sigma\$\`u:id\`);
            write.table(mix\$U\$\`u:id\`, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:rowNumberFactor\`, file=\''.$stats_out_tempfile_row.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:colNumberFactor\`, file=\''.$stats_out_tempfile_col.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mix\$data\$plot_id, residuals = mix\$residuals, fitted = mix\$fitted), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            X <- with(mat, spl2D(rowNumber, colNumber));
            spatial_blup_results <- data.frame(plot_id = mat\$plot_id);
            blups1 <- mix\$U\$\`u:rowNumber\`\$'.$t.';
            spatial_blup_results\$'.$t.' <- data.matrix(X) %*% data.matrix(blups1);
            write.table(spatial_blup_results, file=\''.$stats_out_tempfile_2dspl.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            # print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };
            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;

                open(my $fh, '<', $stats_out_tempfile)
                    or die "Could not open file '$stats_out_tempfile' $!";

                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;
                    my @header_cols;
                    if ($csv->parse($header)) {
                        @header_cols = $csv->fields();
                    }

                    while (my $row = <$fh>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $stock_id = $columns[0];

                                my $stock_name = $stock_info{$stock_id}->{uniquename};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_data_altered_env_3->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $genetic_effect_min_altered_env_3) {
                                        $genetic_effect_min_altered_env_3 = $value;
                                    }
                                    elsif ($value >= $genetic_effect_max_altered_env_3) {
                                        $genetic_effect_max_altered_env_3 = $value;
                                    }

                                    $genetic_effect_sum_altered_env_3 += abs($value);
                                    $genetic_effect_sum_square_altered_env_3 = $genetic_effect_sum_square_altered_env_3 + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_gen_row_count++;
                    }
                close($fh);

                open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                    or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                    print STDERR "Opened $stats_out_tempfile_2dspl\n";
                    my $header_2dspl = <$fh_2dspl>;
                    my @header_cols_2dspl;
                    if ($csv->parse($header_2dspl)) {
                        @header_cols_2dspl = $csv->fields();
                    }
                    shift @header_cols_2dspl;
                    while (my $row_2dspl = <$fh_2dspl>) {
                        my @columns;
                        if ($csv->parse($row_2dspl)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols_2dspl) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $plot_id = $columns[0];

                                my $plot_name = $plot_id_map{$plot_id};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_spatial_data_altered_env_3->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $env_effect_min_altered_env_3) {
                                        $env_effect_min_altered_env_3 = $value;
                                    }
                                    elsif ($value >= $env_effect_max_altered_env_3) {
                                        $env_effect_max_altered_env_3 = $value;
                                    }

                                    $env_effect_sum_altered_env_3 += abs($value);
                                    $env_effect_sum_square_altered_env_3 = $env_effect_sum_square_altered_env_3 + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_env_row_count++;
                    }
                close($fh_2dspl);

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $trait_name = $trait_name_encoder_rev{$t};
                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_3->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_3 += abs($residual);
                            $residual_sum_square_altered_env_3 = $residual_sum_square_altered_env_3 + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_3->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_3 = $model_sum_square_residual_altered_env_3 + $residual*$residual;
                    }
                close($fh_residual);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {

        print STDERR Dumper $statistics_cmd;
        my $status_r = system($statistics_cmd);

        my @pheno_var;
        open(my $fh_r, '<', $stats_out_param_tempfile)
            or die "Could not open file '$stats_out_param_tempfile' $!";
            print STDERR "Opened $stats_out_param_tempfile\n";

            while (my $row = <$fh_r>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                push @pheno_var, \@columns;
            }
        close($fh_r);
        # print STDERR Dumper \@pheno_var;

        my $stats_tempfile_2_basename = basename($stats_tempfile_2);
        my $grm_file_basename = basename($grm_rename_tempfile);
        my $permanent_environment_structure_file_basename = basename($permanent_environment_structure_tempfile);
        my $permanent_environment_structure_env_file_basename = basename($permanent_environment_structure_env_tempfile_mat);
        #my @phenotype_header = ("id", "plot_id", "replicate", "time", "replicate_time", "ind_replicate", @sorted_trait_names, "phenotype");

        my $effect_1_levels = scalar(@rep_time_factors);
        my $effect_grm_levels = scalar(@unique_accession_names);
        my $effect_pe_levels = scalar(@ind_rep_factors);

        my @param_file_rows = (
            'DATAFILE',
            $stats_tempfile_2_basename,
            'NUMBER_OF_TRAITS',
            '1',
            'NUMBER_OF_EFFECTS',
            ($legendre_order_number + 1)*2 + 1,
            'OBSERVATION(S)',
            $legendre_order_number + 1 + 6 + 1,
            'WEIGHT(S)',
            '',
            'EFFECTS: POSITION_IN_DATAFILE NUMBER_OF_LEVELS TYPE_OF_EFFECT',
            '5 '.$effect_1_levels.' cross',
        );
        my $p_counter = 1;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p_counter.' '.$effect_grm_levels.' cov 1';
            $p_counter++;
        }
        my $p2_counter = 1;
        my @hetres_group;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p2_counter.' '.$effect_pe_levels.' cov 6';
            push @hetres_group, 6+$p2_counter;
            $p2_counter++;
        }
        my @random_group1;
        foreach (1..$legendre_order_number+1) {
            push @random_group1, 1+$_;
        }
        my $random_group_string1 = join ' ', @random_group1;
        my @random_group2;
        foreach (1..$legendre_order_number+1) {
            push @random_group2, 1+scalar(@random_group1)+$_;
        }
        my $random_group_string2 = join ' ', @random_group2;
        my $hetres_group_string = join ' ', @hetres_group;
        push @param_file_rows, (
            'RANDOM_RESIDUAL VALUES',
            '1',
            'RANDOM_GROUP',
            $random_group_string1,
            'RANDOM_TYPE',
            'user_file_inv',
            'FILE',
            $grm_file_basename,
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        push @param_file_rows, (
            'RANDOM_GROUP',
            $random_group_string2,
            'RANDOM_TYPE'
        );

        if ($permanent_environment_structure eq 'identity') {
            push @param_file_rows, (
                'diagonal',
                'FILE',
                ''
            );
        }
        elsif ($permanent_environment_structure eq 'env_corr_structure') {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_env_file_basename
            );
        }
        else {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_file_basename
            );
        }

        push @param_file_rows, (
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        my $hetres_pol_string = join ' ', @sorted_scaled_ln_times;
        push @param_file_rows, (
            'OPTION hetres_pos '.$hetres_group_string,
            'OPTION hetres_pol '.$hetres_pol_string,
            'OPTION conv_crit '.$tolparinv,
            'OPTION residual',
        );

        open(my $Fp, ">", $parameter_tempfile) || die "Can't open file ".$parameter_tempfile;
            foreach (@param_file_rows) {
                print $Fp "$_\n";
            }
        close($Fp);

        print STDERR Dumper $cmd_f90;
        my $status = system($cmd_f90);

        open(my $fh_log, '<', $stats_out_tempfile)
            or die "Could not open file '$stats_out_tempfile' $!";

            print STDERR "Opened $stats_out_tempfile\n";
            while (my $row = <$fh_log>) {
                print STDERR $row;
            }
        close($fh_log);

        my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
        my $h_time = $schema->storage->dbh()->prepare($q_time);

        $yhat_residual_tempfile = $tmp_stats_dir."/yhat_residual";
        open(my $fh_yhat_res, '<', $yhat_residual_tempfile)
            or die "Could not open file '$yhat_residual_tempfile' $!";
            print STDERR "Opened $yhat_residual_tempfile\n";

            my $pred_res_counter = 0;
            my $trait_counter = 0;
            while (my $row = <$fh_yhat_res>) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $pred = $vals[0];
                my $residual = $vals[1];
                $model_sum_square_residual_altered_env_3 = $model_sum_square_residual_altered_env_3 + $residual*$residual;

                my $plot_name = $plot_id_count_map_reverse{$pred_res_counter};
                my $time = $time_count_map_reverse{$pred_res_counter};

                if (defined $residual && $residual ne '') {
                    $result_residual_data_altered_env_3->{$plot_name}->{$seen_times{$time}} = [$residual, $timestamp, $user_name, '', ''];
                    $residual_sum_altered_env_3 += abs($residual);
                    $residual_sum_square_altered_env_3 = $residual_sum_square_altered_env_3 + $residual*$residual;
                }
                if (defined $pred && $pred ne '') {
                    $result_fitted_data_altered_env_3->{$plot_name}->{$seen_times{$time}} = [$pred, $timestamp, $user_name, '', ''];
                }

                $pred_res_counter++;
            }
        close($fh_yhat_res);

        $blupf90_solutions_tempfile = $tmp_stats_dir."/solutions";
        open(my $fh_sol, '<', $blupf90_solutions_tempfile)
            or die "Could not open file '$blupf90_solutions_tempfile' $!";
            print STDERR "Opened $blupf90_solutions_tempfile\n";

            my $head = <$fh_sol>;
            print STDERR $head;

            my $solution_file_counter = 0;
            my $grm_sol_counter = 0;
            my $grm_sol_trait_counter = 0;
            my $pe_sol_counter = 0;
            my $pe_sol_trait_counter = 0;
            while (defined(my $row = <$fh_sol>)) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $level = $vals[2];
                my $value = $vals[3];
                if ($solution_file_counter < $effect_1_levels) {
                    $fixed_effects_altered_env_3{$solution_file_counter}->{$level} = $value;
                }
                elsif ($solution_file_counter < $effect_1_levels + $effect_grm_levels*($legendre_order_number+1)) {
                    my $accession_name = $accession_id_factor_map_reverse{$level};
                    if ($grm_sol_counter < $effect_grm_levels-1) {
                        $grm_sol_counter++;
                    }
                    else {
                        $grm_sol_counter = 0;
                        $grm_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_genetic_coefficients_altered_env_3{$accession_name}}, $value;
                    }
                }
                else {
                    my $plot_name = $plot_id_factor_map_reverse{$level};
                    if ($pe_sol_counter < $effect_pe_levels-1) {
                        $pe_sol_counter++;
                    }
                    else {
                        $pe_sol_counter = 0;
                        $pe_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_temporal_coefficients_altered_env_3{$plot_name}}, $value;
                    }
                }
                $solution_file_counter++;
            }
        close($fh_sol);

        # print STDERR Dumper \%rr_genetic_coefficients_altered;
        # print STDERR Dumper \%rr_temporal_coefficients_altered;

        open(my $Fgc, ">", $coeff_genetic_tempfile) || die "Can't open file ".$coeff_genetic_tempfile;

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env_3) {
            my @line = ($accession_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fgc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_blup = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_data_altered_env_3->{$accession_name}->{$time_term_string_blup} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fgc);

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env_3) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_data_delta_altered_env_3->{$accession_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $genetic_effect_min_altered_env_3) {
                    $genetic_effect_min_altered_env_3 = $value;
                }
                elsif ($value >= $genetic_effect_max_altered_env_3) {
                    $genetic_effect_max_altered_env_3 = $value;
                }

                $genetic_effect_sum_altered_env_3 += abs($value);
                $genetic_effect_sum_square_altered_env_3 = $genetic_effect_sum_square_altered_env_3 + $value*$value;
            }
        }

        open(my $Fpc, ">", $coeff_pe_tempfile) || die "Can't open file ".$coeff_pe_tempfile;

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env_3) {
            my @line = ($plot_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fpc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_pe = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_pe_data_altered_env_3->{$plot_name}->{$time_term_string_pe} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fpc);

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env_3) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_pe_data_delta_altered_env_3->{$plot_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $env_effect_min_altered_env_3) {
                    $env_effect_min_altered_env_3 = $value;
                }
                elsif ($value >= $env_effect_max_altered_env_3) {
                    $env_effect_max_altered_env_3 = $value;
                }

                $env_effect_sum_altered_env_3 += abs($value);
                $env_effect_sum_square_altered_env_3 = $env_effect_sum_square_altered_env_3 + $value*$value;
            }
        }
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $t (@sorted_trait_names) {

            $statistics_cmd = 'R -e "library(asreml); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile_2.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_rename_tempfile.'\', header=FALSE, sep=\' \'));
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumber);
            mat\$colNumberFactor <- as.factor(mat\$colNumber);
            mat\$id_factor <- as.factor(mat\$id_factor);
            mat <- mat[order(mat\$rowNumber, mat\$colNumber),];
            attr(geno_mat_3col,\'rowNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'colNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'INVERSE\') <- TRUE;
            mix <- asreml(t'.$t.'~1 + replicate, random=~vm(id_factor, geno_mat_3col) + ar1(rowNumberFactor):ar1v(colNumberFactor), residual=~idv(units), data=mat);
            if (!is.null(summary(mix,coef=TRUE)\$coef.random)) {
            write.table(summary(mix,coef=TRUE)\$coef.random, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mat\$plot_id, residuals = mix\$residuals, fitted = mix\$linear.predictors), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };

            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;
                my @row_col_ordered_plots_names;

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        push @row_col_ordered_plots_names, $stock_name;
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_3->{$stock_name}->{$t} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_3 += abs($residual);
                            $residual_sum_square_altered_env_3 = $residual_sum_square_altered_env_3 + $residual*$residual;}
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_3->{$stock_name}->{$t} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_3 = $model_sum_square_residual_altered_env_3 + $residual*$residual;
                    }
                close($fh_residual);

                open(my $fh, '<', $stats_out_tempfile) or die "Could not open file '$stats_out_tempfile' $!";
                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;

                    my $solution_file_counter = 0;
                    while (defined(my $row = <$fh>)) {
                        # print STDERR $row;
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $level = $columns[0];
                        my $value = $columns[1];
                        my $std = $columns[2];
                        my $z_ratio = $columns[3];
                        if (defined $value && $value ne '') {
                            if ($solution_file_counter < $number_accessions) {
                                my $stock_name = $accession_id_factor_map_reverse{$solution_file_counter+1};
                                $result_blup_data_altered_env_3->{$stock_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $genetic_effect_min_altered_env_3) {
                                    $genetic_effect_min_altered_env_3 = $value;
                                }
                                elsif ($value >= $genetic_effect_max_altered_env_3) {
                                    $genetic_effect_max_altered_env_3 = $value;
                                }

                                $genetic_effect_sum_altered_env_3 += abs($value);
                                $genetic_effect_sum_square_altered_env_3 = $genetic_effect_sum_square_altered_env_3 + $value*$value;

                                $current_gen_row_count++;
                            }
                            else {
                                my $plot_name = $row_col_ordered_plots_names[$current_env_row_count-$number_accessions];
                                $result_blup_spatial_data_altered_env_3->{$plot_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $env_effect_min_altered_env_3) {
                                    $env_effect_min_altered_env_3 = $value;
                                }
                                elsif ($value >= $env_effect_max_altered_env_3) {
                                    $env_effect_max_altered_env_3 = $value;
                                }

                                $env_effect_sum_altered_env_3 += abs($value);
                                $env_effect_sum_square_altered_env_3 = $env_effect_sum_square_altered_env_3 + $value*$value;

                                $current_env_row_count++;
                            }
                        }
                        $solution_file_counter++;
                    }
                close($fh);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    print STDERR "ALTERED w/SIM_ENV 2dn $statistics_select GENETIC EFFECT SUM $genetic_effect_sum_altered_env_3\n";
    print STDERR "ALTERED w/SIM_ENV 2dn $statistics_select ENV EFFECT SUM $env_effect_sum_altered_env_3\n";
    print STDERR Dumper [$genetic_effect_min_altered_env_3, $genetic_effect_max_altered_env_3, $env_effect_min_altered_env_3, $env_effect_max_altered_env_3];

    $env_simulation = "random";

    my (%phenotype_data_altered_env_4, @data_matrix_altered_env_4, @data_matrix_phenotypes_altered_env_4);
    my $phenotype_min_altered_env_4 = 1000000000;
    my $phenotype_max_altered_env_4 = -1000000000;
    my $env_sim_min_4 = 10000000000000;
    my $env_sim_max_4 = -10000000000000;
    my %sim_data_4;
    my %sim_data_check_4;

    eval {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $sim_val = eval $env_sim_exec->{$env_simulation};
            $sim_data_check_4{$row_number}->{$col_number} = $sim_val;

            if ($sim_val < $env_sim_min_4) {
                $env_sim_min_4 = $sim_val;
            }
            elsif ($sim_val >= $env_sim_max_4) {
                $env_sim_max_4 = $sim_val;
            }
        }
    };

    if ($permanent_environment_structure eq 'env_corr_structure') {
        my @sim_data_diff_4;
        my $num_plots = scalar(@unique_plot_names);
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $plot_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my $sim_val = $sim_data_check_4{$row_number}->{$col_number};
            my @diffs = ($plot_id, $sim_val);
            foreach my $r (@seen_rows_ordered) {
                foreach my $c (@seen_cols_ordered) {
                    my $v = $sim_data_check_4{$r}->{$c};
                    push @diffs, $sim_val - $v;
                }
            }
            push @sim_data_diff_4, \@diffs;
        }

        open(my $pe_pheno_f, ">", $permanent_environment_structure_env_tempfile) || die "Can't open file ".$permanent_environment_structure_env_tempfile;
            print STDERR "OPENING PERMANENT ENVIRONMENT ENV $env_simulation CORR $permanent_environment_structure_env_tempfile\n";
            foreach (@sim_data_diff_4) {
                my $line = join "\t", @$_;
                print $pe_pheno_f $line."\n";
            }
        close($pe_pheno_f);

        my $pe_rel_cmd = 'R -e "library(lme4); library(data.table);
        mat_agg <- fread(\''.$permanent_environment_structure_env_tempfile.'\', header=FALSE, sep=\'\t\');
        mat_pheno <- mat_agg[,3:ncol(mat_agg)];
        a <- data.matrix(mat_pheno) - (matrix(rep(1,'.$num_plots.'*'.$num_plots.'), nrow='.$num_plots.') %*% data.matrix(mat_pheno))/'.$num_plots.';
        cor_mat <- a %*% t(a);
        rownames(cor_mat) <- data.matrix(mat_agg[,1]);
        colnames(cor_mat) <- data.matrix(mat_agg[,1]);
        range01 <- function(x){(x-min(x))/(max(x)-min(x))};
        cor_mat <- range01(cor_mat);
        write.table(cor_mat, file=\''.$permanent_environment_structure_env_tempfile2.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');"';
        # print STDERR Dumper $pe_rel_cmd;
        my $status_pe_rel = system($pe_rel_cmd);

        my %rel_pe_result_hash;
        open(my $pe_rel_res, '<', $permanent_environment_structure_env_tempfile2) or die "Could not open file '$permanent_environment_structure_env_tempfile2' $!";
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE $permanent_environment_structure_env_tempfile2\n";
            my $header_row = <$pe_rel_res>;
            my @header;
            if ($csv->parse($header_row)) {
                @header = $csv->fields();
            }

            while (my $row = <$pe_rel_res>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                my $stock_id1 = $columns[0];
                my $counter = 1;
                foreach my $stock_id2 (@header) {
                    my $val = $columns[$counter];
                    $rel_pe_result_hash{$stock_id1}->{$stock_id2} = $val;
                    $counter++;
                }
            }
        close($pe_rel_res);

        my $data_rel_pe = '';
        my %result_hash_pe;
        foreach my $s (sort { $a <=> $b } @plot_ids_ordered) {
            foreach my $r (sort { $a <=> $b } @plot_ids_ordered) {
                my $s_factor = $stock_name_row_col{$plot_id_map{$s}}->{plot_id_factor};
                my $r_factor = $stock_name_row_col{$plot_id_map{$r}}->{plot_id_factor};
                if (!exists($result_hash_pe{$s_factor}->{$r_factor}) && !exists($result_hash_pe{$r_factor}->{$s_factor})) {
                    $result_hash_pe{$s_factor}->{$r_factor} = $rel_pe_result_hash{$s}->{$r};
                }
            }
        }
        foreach my $r (sort { $a <=> $b } keys %result_hash_pe) {
            foreach my $s (sort { $a <=> $b } keys %{$result_hash_pe{$r}}) {
                my $val = $result_hash_pe{$r}->{$s};
                if (defined $val and length $val) {
                    $data_rel_pe .= "$r\t$s\t$val\n";
                }
            }
        }

        open(my $pe_rel_out, ">", $permanent_environment_structure_env_tempfile_mat) || die "Can't open file ".$permanent_environment_structure_env_tempfile_mat;
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE 3col $permanent_environment_structure_env_tempfile_mat\n";
            print $pe_rel_out $data_rel_pe;
        close($pe_rel_out);
    }

    print STDERR "ADD SIMULATED ENV TO ALTERED PHENO random\n";
    print STDERR Dumper [$env_sim_min_4, $env_sim_max_4];
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_genetic_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my @row = ($replicate, $block, "S".$germplasm_stock_id, $obsunit_stock_id, $row_number, $col_number, $row_number, $col_number);

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = eval $env_sim_exec->{$env_simulation};
                    $sim_val = (($sim_val - $env_sim_min_4)/($env_sim_max_4 - $env_sim_min_4))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env_4) {
                        $phenotype_min_altered_env_4 = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env_4) {
                        $phenotype_max_altered_env_4 = $new_val;
                    }

                    $sim_data_4{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env_4{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, 'NA';
                }
            }
            push @data_matrix_altered_env_4, \@row;
        }

        open(my $F, ">", $stats_tempfile) || die "Can't open file ".$stats_tempfile;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env_4) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @data_matrix_phenotypes_row;
            my $current_trait_index = 0;
            foreach my $t (@sorted_trait_names) {
                my @row = (
                    $accession_id_factor_map{$germplasm_stock_id},
                    $obsunit_stock_id,
                    $replicate,
                    $t,
                    $plot_rep_time_factor_map{$obsunit_stock_id}->{$replicate}->{$t},
                    $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
                );

                my $polys = $polynomial_map{$t};
                push @row, @$polys;

                if (defined($phenotype_data_altered{$p}->{$t})) {
                    if ($use_area_under_curve) {
                        my $val = 0;
                        foreach my $counter (0..$current_trait_index) {
                            if ($counter == 0) {
                                $val = $val + $phenotype_data_altered{$p}->{$sorted_trait_names[$counter]} + 0;
                            }
                            else {
                                my $t1 = $sorted_trait_names[$counter-1];
                                my $t2 = $sorted_trait_names[$counter];
                                my $p1 = $phenotype_data_altered{$p}->{$t1} + 0;
                                my $p2 = $phenotype_data_altered{$p}->{$t2} + 0;
                                my $neg = 1;
                                my $min_val = $p1;
                                if ($p2 < $p1) {
                                    $neg = -1;
                                    $min_val = $p2;
                                }
                                $val = $val + (($neg*($p2-$p1)*($t2-$t1))/2)+($t2-$t1)*$min_val;
                            }
                        }

                        my $sim_val = eval $env_sim_exec->{$env_simulation};
                        $sim_val = (($sim_val - $env_sim_min_4)/($env_sim_max_4 - $env_sim_min_4))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env_4) {
                            $phenotype_min_altered_env_4 = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env_4) {
                            $phenotype_max_altered_env_4 = $val;
                        }

                        $sim_data_4{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env_4{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                    else {
                        my $val = $phenotype_data_altered{$p}->{$t} + 0;

                        my $sim_val = eval $env_sim_exec->{$env_simulation};
                        $sim_val = (($sim_val - $env_sim_min_4)/($env_sim_max_4 - $env_sim_min_4))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env_4) {
                            $phenotype_min_altered_env_4 = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env_4) {
                            $phenotype_max_altered_env_4 = $val;
                        }

                        $sim_data_4{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env_4{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                    push @data_matrix_phenotypes_row, 'NA';
                }

                push @data_matrix_altered_env_4, \@row;
                push @data_matrix_phenotypes_altered_env_4, \@data_matrix_phenotypes_row;

                $current_trait_index++;
            }
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            foreach (@data_matrix_altered_env_4) {
                my $line = join ' ', @$_;
                print $F "$line\n";
            }
        close($F);

        open(my $F2, ">", $stats_prep2_tempfile) || die "Can't open file ".$stats_prep2_tempfile;
            foreach (@data_matrix_phenotypes_altered_env_4) {
                my $line = join ',', @$_;
                print $F2 "$line\n";
            }
        close($F2);
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @row = (
                $germplasm_stock_id,
                $obsunit_stock_id,
                $replicate,
                $row_number,
                $col_number,
                $accession_id_factor_map{$germplasm_stock_id},
                $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
            );

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = eval $env_sim_exec->{$env_simulation};
                    $sim_val = (($sim_val - $env_sim_min_4)/($env_sim_max_4 - $env_sim_min_4))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env_4) {
                        $phenotype_min_altered_env_4 = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env_4) {
                        $phenotype_max_altered_env_4 = $new_val;
                    }

                    $sim_data_4{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env_4{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                }
            }
            push @data_matrix_altered_env_4, \@row;
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env_4) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }

    print STDERR Dumper [$phenotype_min_altered_env_4, $phenotype_max_altered_env_4];

    my ($result_blup_data_altered_env_4, $result_blup_data_delta_altered_env_4, $result_blup_spatial_data_altered_env_4, $result_blup_pe_data_altered_env_4, $result_blup_pe_data_delta_altered_env_4, $result_residual_data_altered_env_4, $result_fitted_data_altered_env_4, %fixed_effects_altered_env_4, %rr_genetic_coefficients_altered_env_4, %rr_temporal_coefficients_altered_env_4);
    my $model_sum_square_residual_altered_env_4 = 0;
    my $genetic_effect_min_altered_env_4 = 1000000000;
    my $genetic_effect_max_altered_env_4 = -1000000000;
    my $env_effect_min_altered_env_4 = 1000000000;
    my $env_effect_max_altered_env_4 = -1000000000;
    my $genetic_effect_sum_square_altered_env_4 = 0;
    my $genetic_effect_sum_altered_env_4 = 0;
    my $env_effect_sum_square_altered_env_4 = 0;
    my $env_effect_sum_altered_env_4 = 0;
    my $residual_sum_square_altered_env_4 = 0;
    my $residual_sum_altered_env_4 = 0;

    print STDERR "RUN ENV ESTIMATE ON Altered Pheno With Sim Env random\n";
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups') {
        # print STDERR Dumper $statistics_cmd;
        eval {
            my $status = system($statistics_cmd);
        };
        my $run_stats_fault = 0;
        if ($@) {
            print STDERR "R ERROR\n";
            print STDERR Dumper $@;
            $run_stats_fault = 1;
        }
        else {
            my $current_gen_row_count = 0;
            my $current_env_row_count = 0;

            open(my $fh, '<', $stats_out_tempfile)
                or die "Could not open file '$stats_out_tempfile' $!";

                print STDERR "Opened $stats_out_tempfile\n";
                my $header = <$fh>;
                my @header_cols;
                if ($csv->parse($header)) {
                    @header_cols = $csv->fields();
                }

                while (my $row = <$fh>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $stock_id = $columns[0];

                        my $stock_name = $stock_info{$stock_id}->{uniquename};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_data_altered_env_4->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $genetic_effect_min_altered_env_4) {
                                $genetic_effect_min_altered_env_4 = $value;
                            }
                            elsif ($value >= $genetic_effect_max_altered_env_4) {
                                $genetic_effect_max_altered_env_4 = $value;
                            }

                            $genetic_effect_sum_altered_env_4 += abs($value);
                            $genetic_effect_sum_square_altered_env_4 = $genetic_effect_sum_square_altered_env_4 + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_gen_row_count++;
                }
            close($fh);

            open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                print STDERR "Opened $stats_out_tempfile_2dspl\n";
                my $header_2dspl = <$fh_2dspl>;
                my @header_cols_2dspl;
                if ($csv->parse($header_2dspl)) {
                    @header_cols_2dspl = $csv->fields();
                }
                shift @header_cols_2dspl;
                while (my $row_2dspl = <$fh_2dspl>) {
                    my @columns;
                    if ($csv->parse($row_2dspl)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols_2dspl) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $plot_id = $columns[0];

                        my $plot_name = $plot_id_map{$plot_id};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_spatial_data_altered_env_4->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $env_effect_min_altered_env_4) {
                                $env_effect_min_altered_env_4 = $value;
                            }
                            elsif ($value >= $env_effect_max_altered_env_4) {
                                $env_effect_max_altered_env_4 = $value;
                            }

                            $env_effect_sum_altered_env_4 += abs($value);
                            $env_effect_sum_square_altered_env_4 = $env_effect_sum_square_altered_env_4 + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_env_row_count++;
                }
            close($fh_2dspl);

            open(my $fh_residual, '<', $stats_out_tempfile_residual)
                or die "Could not open file '$stats_out_tempfile_residual' $!";
            
                print STDERR "Opened $stats_out_tempfile_residual\n";
                my $header_residual = <$fh_residual>;
                my @header_cols_residual;
                if ($csv->parse($header_residual)) {
                    @header_cols_residual = $csv->fields();
                }
                while (my $row = <$fh_residual>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }

                    my $stock_id = $columns[0];
                    foreach (0..$number_traits-1) {
                        my $trait_name = $sorted_trait_names[$_];
                        my $residual = $columns[1 + $_];
                        my $fitted = $columns[1 + $number_traits + $_];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_4->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_4 += abs($residual);
                            $residual_sum_square_altered_env_4 = $residual_sum_square_altered_env_4 + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_4->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_4 = $model_sum_square_residual_altered_env_4 + $residual*$residual;
                    }
                }
            close($fh_residual);

            if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                $run_stats_fault = 1;
            }
        }

        if ($run_stats_fault == 1) {
            $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
            $c->detach();
            print STDERR "ERROR IN R CMD\n";
        }
    }
    elsif ($statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups') {
        my @encoded_traits = values %trait_name_encoder;
        foreach my $t (@encoded_traits) {

            $statistics_cmd = 'R -e "library(sommer); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_file.'\', header=FALSE, sep=\'\t\'));
            geno_mat <- acast(geno_mat_3col, V1~V2, value.var=\'V3\');
            geno_mat[is.na(geno_mat)] <- 0;
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumberFactor);
            mat\$colNumberFactor <- as.factor(mat\$colNumberFactor);
            mix <- mmer('.$t.'~1 + replicate, random=~vs(id, Gu=geno_mat, Gtc=unsm(1)) +vs(rowNumberFactor, Gtc=diag(1)) +vs(colNumberFactor, Gtc=diag(1)) +vs(spl2D(rowNumber, colNumber), Gtc=diag(1)), rcov=~vs(units, Gtc=unsm(1)), data=mat, tolparinv='.$tolparinv.');
            if (!is.null(mix\$U)) {
            #gen_cor <- cov2cor(mix\$sigma\$\`u:id\`);
            write.table(mix\$U\$\`u:id\`, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:rowNumberFactor\`, file=\''.$stats_out_tempfile_row.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:colNumberFactor\`, file=\''.$stats_out_tempfile_col.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mix\$data\$plot_id, residuals = mix\$residuals, fitted = mix\$fitted), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            X <- with(mat, spl2D(rowNumber, colNumber));
            spatial_blup_results <- data.frame(plot_id = mat\$plot_id);
            blups1 <- mix\$U\$\`u:rowNumber\`\$'.$t.';
            spatial_blup_results\$'.$t.' <- data.matrix(X) %*% data.matrix(blups1);
            write.table(spatial_blup_results, file=\''.$stats_out_tempfile_2dspl.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            # print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };
            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;

                open(my $fh, '<', $stats_out_tempfile)
                    or die "Could not open file '$stats_out_tempfile' $!";

                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;
                    my @header_cols;
                    if ($csv->parse($header)) {
                        @header_cols = $csv->fields();
                    }

                    while (my $row = <$fh>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $stock_id = $columns[0];

                                my $stock_name = $stock_info{$stock_id}->{uniquename};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_data_altered_env_4->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $genetic_effect_min_altered_env_4) {
                                        $genetic_effect_min_altered_env_4 = $value;
                                    }
                                    elsif ($value >= $genetic_effect_max_altered_env_4) {
                                        $genetic_effect_max_altered_env_4 = $value;
                                    }

                                    $genetic_effect_sum_altered_env_4 += abs($value);
                                    $genetic_effect_sum_square_altered_env_4 = $genetic_effect_sum_square_altered_env_4 + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_gen_row_count++;
                    }
                close($fh);

                open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl)
                    or die "Could not open file '$stats_out_tempfile_2dspl' $!";

                    print STDERR "Opened $stats_out_tempfile_2dspl\n";
                    my $header_2dspl = <$fh_2dspl>;
                    my @header_cols_2dspl;
                    if ($csv->parse($header_2dspl)) {
                        @header_cols_2dspl = $csv->fields();
                    }
                    shift @header_cols_2dspl;
                    while (my $row_2dspl = <$fh_2dspl>) {
                        my @columns;
                        if ($csv->parse($row_2dspl)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols_2dspl) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $plot_id = $columns[0];

                                my $plot_name = $plot_id_map{$plot_id};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_spatial_data_altered_env_4->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $env_effect_min_altered_env_4) {
                                        $env_effect_min_altered_env_4 = $value;
                                    }
                                    elsif ($value >= $env_effect_max_altered_env_4) {
                                        $env_effect_max_altered_env_4 = $value;
                                    }

                                    $env_effect_sum_altered_env_4 += abs($value);
                                    $env_effect_sum_square_altered_env_4 = $env_effect_sum_square_altered_env_4 + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_env_row_count++;
                    }
                close($fh_2dspl);

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $trait_name = $trait_name_encoder_rev{$t};
                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_4->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_4 += abs($residual);
                            $residual_sum_square_altered_env_4 = $residual_sum_square_altered_env_4 + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_4->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_4 = $model_sum_square_residual_altered_env_4 + $residual*$residual;
                    }
                close($fh_residual);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {

        print STDERR Dumper $statistics_cmd;
        my $status_r = system($statistics_cmd);

        my @pheno_var;
        open(my $fh_r, '<', $stats_out_param_tempfile)
            or die "Could not open file '$stats_out_param_tempfile' $!";
            print STDERR "Opened $stats_out_param_tempfile\n";

            while (defined(my $row = <$fh_r>)) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                push @pheno_var, \@columns;
            }
        close($fh_r);
        # print STDERR Dumper \@pheno_var;

        my $stats_tempfile_2_basename = basename($stats_tempfile_2);
        my $grm_file_basename = basename($grm_rename_tempfile);
        my $permanent_environment_structure_file_basename = basename($permanent_environment_structure_tempfile);
        my $permanent_environment_structure_env_file_basename = basename($permanent_environment_structure_env_tempfile_mat);
        #my @phenotype_header = ("id", "plot_id", "replicate", "time", "replicate_time", "ind_replicate", @sorted_trait_names, "phenotype");

        my $effect_1_levels = scalar(@rep_time_factors);
        my $effect_grm_levels = scalar(@unique_accession_names);
        my $effect_pe_levels = scalar(@ind_rep_factors);

        my @param_file_rows = (
            'DATAFILE',
            $stats_tempfile_2_basename,
            'NUMBER_OF_TRAITS',
            '1',
            'NUMBER_OF_EFFECTS',
            ($legendre_order_number + 1)*2 + 1,
            'OBSERVATION(S)',
            $legendre_order_number + 1 + 6 + 1,
            'WEIGHT(S)',
            '',
            'EFFECTS: POSITION_IN_DATAFILE NUMBER_OF_LEVELS TYPE_OF_EFFECT',
            '5 '.$effect_1_levels.' cross',
        );
        my $p_counter = 1;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p_counter.' '.$effect_grm_levels.' cov 1';
            $p_counter++;
        }
        my $p2_counter = 1;
        my @hetres_group;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p2_counter.' '.$effect_pe_levels.' cov 6';
            push @hetres_group, 6+$p2_counter;
            $p2_counter++;
        }
        my @random_group1;
        foreach (1..$legendre_order_number+1) {
            push @random_group1, 1+$_;
        }
        my $random_group_string1 = join ' ', @random_group1;
        my @random_group2;
        foreach (1..$legendre_order_number+1) {
            push @random_group2, 1+scalar(@random_group1)+$_;
        }
        my $random_group_string2 = join ' ', @random_group2;
        my $hetres_group_string = join ' ', @hetres_group;
        push @param_file_rows, (
            'RANDOM_RESIDUAL VALUES',
            '1',
            'RANDOM_GROUP',
            $random_group_string1,
            'RANDOM_TYPE',
            'user_file_inv',
            'FILE',
            $grm_file_basename,
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        push @param_file_rows, (
            'RANDOM_GROUP',
            $random_group_string2,
            'RANDOM_TYPE'
        );

        if ($permanent_environment_structure eq 'identity') {
            push @param_file_rows, (
                'diagonal',
                'FILE',
                ''
            );
        }
        elsif ($permanent_environment_structure eq 'env_corr_structure') {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_env_file_basename
            );
        }
        else {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_file_basename
            );
        }

        push @param_file_rows, (
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        my $hetres_pol_string = join ' ', @sorted_scaled_ln_times;
        push @param_file_rows, (
            'OPTION hetres_pos '.$hetres_group_string,
            'OPTION hetres_pol '.$hetres_pol_string,
            'OPTION conv_crit '.$tolparinv,
            'OPTION residual',
        );

        open(my $Fp, ">", $parameter_tempfile) || die "Can't open file ".$parameter_tempfile;
            foreach (@param_file_rows) {
                print $Fp "$_\n";
            }
        close($Fp);

        print STDERR Dumper $cmd_f90;
        my $status = system($cmd_f90);

        open(my $fh_log, '<', $stats_out_tempfile)
            or die "Could not open file '$stats_out_tempfile' $!";

            print STDERR "Opened $stats_out_tempfile\n";
            while (my $row = <$fh_log>) {
                print STDERR $row;
            }
        close($fh_log);

        my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
        my $h_time = $schema->storage->dbh()->prepare($q_time);

        $yhat_residual_tempfile = $tmp_stats_dir."/yhat_residual";
        open(my $fh_yhat_res, '<', $yhat_residual_tempfile)
            or die "Could not open file '$yhat_residual_tempfile' $!";
            print STDERR "Opened $yhat_residual_tempfile\n";

            my $pred_res_counter = 0;
            my $trait_counter = 0;
            while (my $row = <$fh_yhat_res>) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $pred = $vals[0];
                my $residual = $vals[1];
                $model_sum_square_residual_altered_env_4 = $model_sum_square_residual_altered_env_4 + $residual*$residual;

                my $plot_name = $plot_id_count_map_reverse{$pred_res_counter};
                my $time = $time_count_map_reverse{$pred_res_counter};

                if (defined $residual && $residual ne '') {
                    $result_residual_data_altered_env_4->{$plot_name}->{$seen_times{$time}} = [$residual, $timestamp, $user_name, '', ''];
                    $residual_sum_altered_env_4 += abs($residual);
                    $residual_sum_square_altered_env_4 = $residual_sum_square_altered_env_4 + $residual*$residual;
                }
                if (defined $pred && $pred ne '') {
                    $result_fitted_data_altered_env_4->{$plot_name}->{$seen_times{$time}} = [$pred, $timestamp, $user_name, '', ''];
                }

                $pred_res_counter++;
            }
        close($fh_yhat_res);

        $blupf90_solutions_tempfile = $tmp_stats_dir."/solutions";
        open(my $fh_sol, '<', $blupf90_solutions_tempfile)
            or die "Could not open file '$blupf90_solutions_tempfile' $!";
            print STDERR "Opened $blupf90_solutions_tempfile\n";

            my $head = <$fh_sol>;
            print STDERR $head;

            my $solution_file_counter = 0;
            my $grm_sol_counter = 0;
            my $grm_sol_trait_counter = 0;
            my $pe_sol_counter = 0;
            my $pe_sol_trait_counter = 0;
            while (defined(my $row = <$fh_sol>)) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $level = $vals[2];
                my $value = $vals[3];
                if ($solution_file_counter < $effect_1_levels) {
                    $fixed_effects_altered_env_4{$solution_file_counter}->{$level} = $value;
                }
                elsif ($solution_file_counter < $effect_1_levels + $effect_grm_levels*($legendre_order_number+1)) {
                    my $accession_name = $accession_id_factor_map_reverse{$level};
                    if ($grm_sol_counter < $effect_grm_levels-1) {
                        $grm_sol_counter++;
                    }
                    else {
                        $grm_sol_counter = 0;
                        $grm_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_genetic_coefficients_altered_env_4{$accession_name}}, $value;
                    }
                }
                else {
                    my $plot_name = $plot_id_factor_map_reverse{$level};
                    if ($pe_sol_counter < $effect_pe_levels-1) {
                        $pe_sol_counter++;
                    }
                    else {
                        $pe_sol_counter = 0;
                        $pe_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_temporal_coefficients_altered_env_4{$plot_name}}, $value;
                    }
                }
                $solution_file_counter++;
            }
        close($fh_sol);

        # print STDERR Dumper \%rr_genetic_coefficients_altered;
        # print STDERR Dumper \%rr_temporal_coefficients_altered;

        open(my $Fgc, ">", $coeff_genetic_tempfile) || die "Can't open file ".$coeff_genetic_tempfile;

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env_4) {
            my @line = ($accession_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fgc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_blup = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_data_altered_env_4->{$accession_name}->{$time_term_string_blup} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fgc);

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env_4) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_data_delta_altered_env_4->{$accession_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $genetic_effect_min_altered_env_4) {
                    $genetic_effect_min_altered_env_4 = $value;
                }
                elsif ($value >= $genetic_effect_max_altered_env_4) {
                    $genetic_effect_max_altered_env_4 = $value;
                }

                $genetic_effect_sum_altered_env_4 += abs($value);
                $genetic_effect_sum_square_altered_env_4 = $genetic_effect_sum_square_altered_env_4 + $value*$value;
            }
        }

        open(my $Fpc, ">", $coeff_pe_tempfile) || die "Can't open file ".$coeff_pe_tempfile;

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env_4) {
            my @line = ($plot_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fpc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_pe = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_pe_data_altered_env_4->{$plot_name}->{$time_term_string_pe} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fpc);

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env_4) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_pe_data_delta_altered_env_4->{$plot_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $env_effect_min_altered_env_4) {
                    $env_effect_min_altered_env_4 = $value;
                }
                elsif ($value >= $env_effect_max_altered_env_4) {
                    $env_effect_max_altered_env_4 = $value;
                }

                $env_effect_sum_altered_env_4 += abs($value);
                $env_effect_sum_square_altered_env_4 = $env_effect_sum_square_altered_env_4 + $value*$value;
            }
        }
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $t (@sorted_trait_names) {

            $statistics_cmd = 'R -e "library(asreml); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile_2.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_rename_tempfile.'\', header=FALSE, sep=\' \'));
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumber);
            mat\$colNumberFactor <- as.factor(mat\$colNumber);
            mat\$id_factor <- as.factor(mat\$id_factor);
            mat <- mat[order(mat\$rowNumber, mat\$colNumber),];
            attr(geno_mat_3col,\'rowNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'colNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'INVERSE\') <- TRUE;
            mix <- asreml(t'.$t.'~1 + replicate, random=~vm(id_factor, geno_mat_3col) + ar1(rowNumberFactor):ar1v(colNumberFactor), residual=~idv(units), data=mat);
            if (!is.null(summary(mix,coef=TRUE)\$coef.random)) {
            write.table(summary(mix,coef=TRUE)\$coef.random, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mat\$plot_id, residuals = mix\$residuals, fitted = mix\$linear.predictors), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };

            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;
                my @row_col_ordered_plots_names;

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        push @row_col_ordered_plots_names, $stock_name;
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_4->{$stock_name}->{$t} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_4 += abs($residual);
                            $residual_sum_square_altered_env_4 = $residual_sum_square_altered_env_4 + $residual*$residual;}
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_4->{$stock_name}->{$t} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_4 = $model_sum_square_residual_altered_env_4 + $residual*$residual;
                    }
                close($fh_residual);

                open(my $fh, '<', $stats_out_tempfile) or die "Could not open file '$stats_out_tempfile' $!";
                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;

                    my $solution_file_counter = 0;
                    while (defined(my $row = <$fh>)) {
                        # print STDERR $row;
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $level = $columns[0];
                        my $value = $columns[1];
                        my $std = $columns[2];
                        my $z_ratio = $columns[3];
                        if (defined $value && $value ne '') {
                            if ($solution_file_counter < $number_accessions) {
                                my $stock_name = $accession_id_factor_map_reverse{$solution_file_counter+1};
                                $result_blup_data_altered_env_4->{$stock_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $genetic_effect_min_altered_env_4) {
                                    $genetic_effect_min_altered_env_4 = $value;
                                }
                                elsif ($value >= $genetic_effect_max_altered_env_4) {
                                    $genetic_effect_max_altered_env_4 = $value;
                                }

                                $genetic_effect_sum_altered_env_4 += abs($value);
                                $genetic_effect_sum_square_altered_env_4 = $genetic_effect_sum_square_altered_env_4 + $value*$value;

                                $current_gen_row_count++;
                            }
                            else {
                                my $plot_name = $row_col_ordered_plots_names[$current_env_row_count-$number_accessions];
                                $result_blup_spatial_data_altered_env_4->{$plot_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $env_effect_min_altered_env_4) {
                                    $env_effect_min_altered_env_4 = $value;
                                }
                                elsif ($value >= $env_effect_max_altered_env_4) {
                                    $env_effect_max_altered_env_4 = $value;
                                }

                                $env_effect_sum_altered_env_4 += abs($value);
                                $env_effect_sum_square_altered_env_4 = $env_effect_sum_square_altered_env_4 + $value*$value;

                                $current_env_row_count++;
                            }
                        }
                        $solution_file_counter++;
                    }
                close($fh);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    print STDERR "ALTERED w/SIM_ENV random $statistics_select GENETIC EFFECT SUM $genetic_effect_sum_altered_env_4\n";
    print STDERR "ALTERED w/SIM_ENV random $statistics_select ENV EFFECT SUM $env_effect_sum_altered_env_4\n";
    print STDERR Dumper [$genetic_effect_min_altered_env_4, $genetic_effect_max_altered_env_4, $env_effect_min_altered_env_4, $env_effect_max_altered_env_4];

    $env_simulation = "ar1xar1";

    my (%phenotype_data_altered_env_5, @data_matrix_altered_env_5, @data_matrix_phenotypes_altered_env_5);
    my $phenotype_min_altered_env_5 = 1000000000;
    my $phenotype_max_altered_env_5 = -1000000000;
    my $env_sim_min_5 = 10000000000000;
    my $env_sim_max_5 = -10000000000000;
    my %sim_data_5;
    my %sim_data_check_5;

    my $col_ro_env = 1 - $row_ro_env;
    my @stock_row_col_id_ordered;
    my $var_e = $phenotype_variance_altered*$env_variance_percent;

    eval {
        foreach my $r (1..$max_row) {
            foreach my $c (1..$max_col) {
                push @stock_row_col_id_ordered, $stock_row_col_id{$r}->{$c};
            }
        }

        my $pe_rel_cmd = 'R -e "library(data.table); library(MASS);
        pr <- '.$row_ro_env.';
        pc <- '.$col_ro_env.';
        Rr <- matrix(0,'.$max_row.','.$max_row.');
        for(i in c(1:'.$max_row.')){
            for(j in c(i:'.$max_row.')){
                Rr[i,j]=pr**(j-i);
                Rr[j,i]=Rr[i,j];
            }
        }
        Rc <- matrix(0,'.$max_col.','.$max_col.');
        for(i in c(1:'.$max_col.')){
            for(j in c(i:'.$max_col.')){
                Rc[i,j]=pc**(j-i);
                Rc[j,i]=Rc[i,j];
            }
        }
        Rscr <- kronecker(Rc,Rr)*'.$var_e.';
        Resscr <- mvrnorm(1,rep(0,length(Rscr[1,])),Rscr);
        write.table(Rscr, file=\''.$permanent_environment_structure_env_tempfile.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');
        write.table(Resscr, file=\''.$permanent_environment_structure_env_tempfile2.'\', row.names=FALSE, col.names=FALSE, sep=\'\t\');"';
        print STDERR Dumper $pe_rel_cmd;
        my $status_pe_rel = system($pe_rel_cmd);

        my %rel_pe_result_hash;
        open(my $pe_rel_res, '<', $permanent_environment_structure_env_tempfile2) or die "Could not open file '$permanent_environment_structure_env_tempfile2' $!";
            print STDERR "Opened PERMANENT ENV $env_simulation VAL FILE $permanent_environment_structure_env_tempfile2\n";

            my $current_row_num = 1;
            my $current_col_num = 1;
            while (my $sim_val = <$pe_rel_res>) {
                chomp $sim_val;

                $sim_data_check_5{$current_row_num}->{$current_col_num} = $sim_val;

                if ($current_col_num < $max_col) {
                    $current_col_num++;
                }
                else {
                    $current_col_num = 1;
                    $current_row_num++;
                }

                if ($sim_val < $env_sim_min_5) {
                    $env_sim_min_5 = $sim_val;
                }
                elsif ($sim_val >= $env_sim_max_5) {
                    $env_sim_max_5 = $sim_val;
                }
            }
        close($pe_rel_res);
    };
    die;

    if ($permanent_environment_structure eq 'env_corr_structure') {
        my %rel_pe_result_hash;
        open(my $pe_rel_res, '<', $permanent_environment_structure_env_tempfile) or die "Could not open file '$permanent_environment_structure_env_tempfile' $!";
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE $permanent_environment_structure_env_tempfile\n";

            my $counter1 = 0;
            while (my $row = <$pe_rel_res>) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                my $stock_id1 = $stock_row_col_id_ordered[$counter1];
                my $counter2 = 0;
                foreach my $stock_id2 (@stock_row_col_id_ordered) {
                    my $val = $columns[$counter2];
                    $rel_pe_result_hash{$stock_id1}->{$stock_id2} = $val;
                    $counter2++;
                }
                $counter1++;
            }
        close($pe_rel_res);

        my $data_rel_pe = '';
        my %result_hash_pe;
        foreach my $s (sort { $a <=> $b } @plot_ids_ordered) {
            foreach my $r (sort { $a <=> $b } @plot_ids_ordered) {
                my $s_factor = $stock_name_row_col{$plot_id_map{$s}}->{plot_id_factor};
                my $r_factor = $stock_name_row_col{$plot_id_map{$r}}->{plot_id_factor};
                if (!exists($result_hash_pe{$s_factor}->{$r_factor}) && !exists($result_hash_pe{$r_factor}->{$s_factor})) {
                    $result_hash_pe{$s_factor}->{$r_factor} = $rel_pe_result_hash{$s}->{$r};
                }
            }
        }
        foreach my $r (sort { $a <=> $b } keys %result_hash_pe) {
            foreach my $s (sort { $a <=> $b } keys %{$result_hash_pe{$r}}) {
                my $val = $result_hash_pe{$r}->{$s};
                if (defined $val and length $val) {
                    $data_rel_pe .= "$r\t$s\t$val\n";
                }
            }
        }

        open(my $pe_rel_out, ">", $permanent_environment_structure_env_tempfile_mat) || die "Can't open file ".$permanent_environment_structure_env_tempfile_mat;
            print STDERR "Opened PERMANENT ENV $env_simulation CORR FILE 3col $permanent_environment_structure_env_tempfile_mat\n";
            print $pe_rel_out $data_rel_pe;
        close($pe_rel_out);
    }

    print STDERR "ADD SIMULATED ENV TO ALTERED PHENO random\n";
    print STDERR Dumper [$env_sim_min_5, $env_sim_max_5];
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups' || $statistics_select eq 'sommer_grm_genetic_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};
            my @row = ($replicate, $block, "S".$germplasm_stock_id, $obsunit_stock_id, $row_number, $col_number, $row_number, $col_number);

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = $sim_data_check_5{$row_number}->{$col_number};
                    $sim_val = (($sim_val - $env_sim_min_5)/($env_sim_max_5 - $env_sim_min_5))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env_5) {
                        $phenotype_min_altered_env_5 = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env_5) {
                        $phenotype_max_altered_env_5 = $new_val;
                    }

                    $sim_data_5{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env_5{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, 'NA';
                }
            }
            push @data_matrix_altered_env_5, \@row;
        }

        open(my $F, ">", $stats_tempfile) || die "Can't open file ".$stats_tempfile;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env_5) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {

        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @data_matrix_phenotypes_row;
            my $current_trait_index = 0;
            foreach my $t (@sorted_trait_names) {
                my @row = (
                    $accession_id_factor_map{$germplasm_stock_id},
                    $obsunit_stock_id,
                    $replicate,
                    $t,
                    $plot_rep_time_factor_map{$obsunit_stock_id}->{$replicate}->{$t},
                    $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
                );

                my $polys = $polynomial_map{$t};
                push @row, @$polys;

                if (defined($phenotype_data_altered{$p}->{$t})) {
                    if ($use_area_under_curve) {
                        my $val = 0;
                        foreach my $counter (0..$current_trait_index) {
                            if ($counter == 0) {
                                $val = $val + $phenotype_data_altered{$p}->{$sorted_trait_names[$counter]} + 0;
                            }
                            else {
                                my $t1 = $sorted_trait_names[$counter-1];
                                my $t2 = $sorted_trait_names[$counter];
                                my $p1 = $phenotype_data_altered{$p}->{$t1} + 0;
                                my $p2 = $phenotype_data_altered{$p}->{$t2} + 0;
                                my $neg = 1;
                                my $min_val = $p1;
                                if ($p2 < $p1) {
                                    $neg = -1;
                                    $min_val = $p2;
                                }
                                $val = $val + (($neg*($p2-$p1)*($t2-$t1))/2)+($t2-$t1)*$min_val;
                            }
                        }

                        my $sim_val = $sim_data_check_5{$row_number}->{$col_number};
                        $sim_val = (($sim_val - $env_sim_min_5)/($env_sim_max_5 - $env_sim_min_5))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env_5) {
                            $phenotype_min_altered_env_5 = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env_5) {
                            $phenotype_max_altered_env_5 = $val;
                        }

                        $sim_data_5{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env_5{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                    else {
                        my $val = $phenotype_data_altered{$p}->{$t} + 0;
                        my $sim_val = $sim_data_check_5{$row_number}->{$col_number};
                        $sim_val = (($sim_val - $env_sim_min_5)/($env_sim_max_5 - $env_sim_min_5))*$env_variance_percent;
                        $val += $sim_val;

                        if ($val < $phenotype_min_altered_env_5) {
                            $phenotype_min_altered_env_5 = $val;
                        }
                        elsif ($val >= $phenotype_max_altered_env_5) {
                            $phenotype_max_altered_env_5 = $val;
                        }

                        $sim_data_5{$p}->{$t} = $sim_val;
                        $phenotype_data_altered_env_5{$p}->{$t} = $val;
                        push @row, $val;
                        push @data_matrix_phenotypes_row, $val;
                    }
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                    push @data_matrix_phenotypes_row, 'NA';
                }

                push @data_matrix_altered_env_5, \@row;
                push @data_matrix_phenotypes_altered_env_5, \@data_matrix_phenotypes_row;

                $current_trait_index++;
            }
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            foreach (@data_matrix_altered_env_5) {
                my $line = join ' ', @$_;
                print $F "$line\n";
            }
        close($F);

        open(my $F2, ">", $stats_prep2_tempfile) || die "Can't open file ".$stats_prep2_tempfile;
            foreach (@data_matrix_phenotypes_altered_env_5) {
                my $line = join ',', @$_;
                print $F2 "$line\n";
            }
        close($F2);
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $p (@unique_plot_names) {
            my $row_number = $stock_name_row_col{$p}->{row_number};
            my $col_number = $stock_name_row_col{$p}->{col_number};
            my $replicate = $stock_name_row_col{$p}->{rep};
            my $block = $stock_name_row_col{$p}->{block};
            my $germplasm_stock_id = $stock_name_row_col{$p}->{germplasm_stock_id};
            my $germplasm_name = $stock_name_row_col{$p}->{germplasm_name};
            my $obsunit_stock_id = $stock_name_row_col{$p}->{obsunit_stock_id};

            my @row = (
                $germplasm_stock_id,
                $obsunit_stock_id,
                $replicate,
                $row_number,
                $col_number,
                $accession_id_factor_map{$germplasm_stock_id},
                $stock_row_col{$obsunit_stock_id}->{plot_id_factor}
            );

            foreach my $t (@sorted_trait_names) {
                if (defined($phenotype_data_altered{$p}->{$t})) {
                    my $new_val = $phenotype_data_altered{$p}->{$t} + 0;
                    my $sim_val = $sim_data_check_5{$row_number}->{$col_number};
                    $sim_val = (($sim_val - $env_sim_min_5)/($env_sim_max_5 - $env_sim_min_5))*$env_variance_percent;
                    $new_val += $sim_val;

                    if ($new_val < $phenotype_min_altered_env_5) {
                        $phenotype_min_altered_env_5 = $new_val;
                    }
                    elsif ($new_val >= $phenotype_max_altered_env_5) {
                        $phenotype_max_altered_env_5 = $new_val;
                    }

                    $sim_data_5{$p}->{$t} = $sim_val;
                    $phenotype_data_altered_env_5{$p}->{$t} = $new_val;
                    push @row, $new_val;
                } else {
                    print STDERR $p." : $t : $germplasm_name : NA \n";
                    push @row, '';
                }
            }
            push @data_matrix_altered_env_5, \@row;
        }

        open(my $F, ">", $stats_tempfile_2) || die "Can't open file ".$stats_tempfile_2;
            print $F $header_string."\n";
            foreach (@data_matrix_altered_env_5) {
                my $line = join ',', @$_;
                print $F "$line\n";
            }
        close($F);
    }
    print STDERR Dumper [$phenotype_min_altered_env_5, $phenotype_max_altered_env_5];

    my ($result_blup_data_altered_env_5, $result_blup_data_delta_altered_env_5, $result_blup_spatial_data_altered_env_5, $result_blup_pe_data_altered_env_5, $result_blup_pe_data_delta_altered_env_5, $result_residual_data_altered_env_5, $result_fitted_data_altered_env_5, %fixed_effects_altered_env_5, %rr_genetic_coefficients_altered_env_5, %rr_temporal_coefficients_altered_env_5);
    my $model_sum_square_residual_altered_env_5 = 0;
    my $genetic_effect_min_altered_env_5 = 1000000000;
    my $genetic_effect_max_altered_env_5 = -1000000000;
    my $env_effect_min_altered_env_5 = 1000000000;
    my $env_effect_max_altered_env_5 = -1000000000;
    my $genetic_effect_sum_square_altered_env_5 = 0;
    my $genetic_effect_sum_altered_env_5 = 0;
    my $env_effect_sum_square_altered_env_5 = 0;
    my $env_effect_sum_altered_env_5 = 0;
    my $residual_sum_square_altered_env_5 = 0;
    my $residual_sum_altered_env_5 = 0;

    print STDERR "RUN ENV ESTIMATE ON Altered Pheno With Sim Env random\n";
    if ($statistics_select eq 'sommer_grm_spatial_genetic_blups') {
        # print STDERR Dumper $statistics_cmd;
        eval {
            my $status = system($statistics_cmd);
        };
        my $run_stats_fault = 0;
        if ($@) {
            print STDERR "R ERROR\n";
            print STDERR Dumper $@;
            $run_stats_fault = 1;
        }
        else {
            my $current_gen_row_count = 0;
            my $current_env_row_count = 0;

            open(my $fh, '<', $stats_out_tempfile)
                or die "Could not open file '$stats_out_tempfile' $!";

                print STDERR "Opened $stats_out_tempfile\n";
                my $header = <$fh>;
                my @header_cols;
                if ($csv->parse($header)) {
                    @header_cols = $csv->fields();
                }

                while (my $row = <$fh>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $stock_id = $columns[0];

                        my $stock_name = $stock_info{$stock_id}->{uniquename};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_data_altered_env_5->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $genetic_effect_min_altered_env_5) {
                                $genetic_effect_min_altered_env_5 = $value;
                            }
                            elsif ($value >= $genetic_effect_max_altered_env_5) {
                                $genetic_effect_max_altered_env_5 = $value;
                            }

                            $genetic_effect_sum_altered_env_5 += abs($value);
                            $genetic_effect_sum_square_altered_env_5 = $genetic_effect_sum_square_altered_env_5 + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_gen_row_count++;
                }
            close($fh);

            open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl) or die "Could not open file '$stats_out_tempfile_2dspl' $!";
                print STDERR "Opened $stats_out_tempfile_2dspl\n";

                my $header_2dspl = <$fh_2dspl>;
                my @header_cols_2dspl;
                if ($csv->parse($header_2dspl)) {
                    @header_cols_2dspl = $csv->fields();
                }
                shift @header_cols_2dspl;
                while (my $row_2dspl = <$fh_2dspl>) {
                    my @columns;
                    if ($csv->parse($row_2dspl)) {
                        @columns = $csv->fields();
                    }
                    my $col_counter = 0;
                    foreach my $encoded_trait (@header_cols_2dspl) {
                        my $trait = $trait_name_encoder_rev{$encoded_trait};
                        my $plot_id = $columns[0];

                        my $plot_name = $plot_id_map{$plot_id};
                        my $value = $columns[$col_counter+1];
                        if (defined $value && $value ne '') {
                            $result_blup_spatial_data_altered_env_5->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                            if ($value < $env_effect_min_altered_env_5) {
                                $env_effect_min_altered_env_5 = $value;
                            }
                            elsif ($value >= $env_effect_max_altered_env_5) {
                                $env_effect_max_altered_env_5 = $value;
                            }

                            $env_effect_sum_altered_env_5 += abs($value);
                            $env_effect_sum_square_altered_env_5 = $env_effect_sum_square_altered_env_5 + $value*$value;
                        }
                        $col_counter++;
                    }
                    $current_env_row_count++;
                }
            close($fh_2dspl);

            open(my $fh_residual, '<', $stats_out_tempfile_residual) or die "Could not open file '$stats_out_tempfile_residual' $!";
                print STDERR "Opened $stats_out_tempfile_residual\n";

                my $header_residual = <$fh_residual>;
                my @header_cols_residual;
                if ($csv->parse($header_residual)) {
                    @header_cols_residual = $csv->fields();
                }
                while (my $row = <$fh_residual>) {
                    my @columns;
                    if ($csv->parse($row)) {
                        @columns = $csv->fields();
                    }

                    my $stock_id = $columns[0];
                    foreach (0..$number_traits-1) {
                        my $trait_name = $sorted_trait_names[$_];
                        my $residual = $columns[1 + $_];
                        my $fitted = $columns[1 + $number_traits + $_];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_5->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_5 += abs($residual);
                            $residual_sum_square_altered_env_5 = $residual_sum_square_altered_env_5 + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_5->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_5 = $model_sum_square_residual_altered_env_5 + $residual*$residual;
                    }
                }
            close($fh_residual);

            if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                $run_stats_fault = 1;
            }
        }

        if ($run_stats_fault == 1) {
            $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
            $c->detach();
            print STDERR "ERROR IN R CMD\n";
        }
    }
    elsif ($statistics_select eq 'sommer_grm_univariate_spatial_genetic_blups') {
        my @encoded_traits = values %trait_name_encoder;
        foreach my $t (@encoded_traits) {

            $statistics_cmd = 'R -e "library(sommer); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_file.'\', header=FALSE, sep=\'\t\'));
            geno_mat <- acast(geno_mat_3col, V1~V2, value.var=\'V3\');
            geno_mat[is.na(geno_mat)] <- 0;
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumberFactor);
            mat\$colNumberFactor <- as.factor(mat\$colNumberFactor);
            mix <- mmer('.$t.'~1 + replicate, random=~vs(id, Gu=geno_mat, Gtc=unsm(1)) +vs(rowNumberFactor, Gtc=diag(1)) +vs(colNumberFactor, Gtc=diag(1)) +vs(spl2D(rowNumber, colNumber), Gtc=diag(1)), rcov=~vs(units, Gtc=unsm(1)), data=mat, tolparinv='.$tolparinv.');
            if (!is.null(mix\$U)) {
            #gen_cor <- cov2cor(mix\$sigma\$\`u:id\`);
            write.table(mix\$U\$\`u:id\`, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:rowNumberFactor\`, file=\''.$stats_out_tempfile_row.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(mix\$U\$\`u:colNumberFactor\`, file=\''.$stats_out_tempfile_col.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mix\$data\$plot_id, residuals = mix\$residuals, fitted = mix\$fitted), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            X <- with(mat, spl2D(rowNumber, colNumber));
            spatial_blup_results <- data.frame(plot_id = mat\$plot_id);
            blups1 <- mix\$U\$\`u:rowNumber\`\$'.$t.';
            spatial_blup_results\$'.$t.' <- data.matrix(X) %*% data.matrix(blups1);
            write.table(spatial_blup_results, file=\''.$stats_out_tempfile_2dspl.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            # print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };
            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;

                open(my $fh, '<', $stats_out_tempfile)
                    or die "Could not open file '$stats_out_tempfile' $!";
    
                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;
                    my @header_cols;
                    if ($csv->parse($header)) {
                        @header_cols = $csv->fields();
                    }

                    while (my $row = <$fh>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $stock_id = $columns[0];

                                my $stock_name = $stock_info{$stock_id}->{uniquename};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_data_altered_env_5->{$stock_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $genetic_effect_min_altered_env_5) {
                                        $genetic_effect_min_altered_env_5 = $value;
                                    }
                                    elsif ($value >= $genetic_effect_max_altered_env_5) {
                                        $genetic_effect_max_altered_env_5 = $value;
                                    }

                                    $genetic_effect_sum_altered_env_5 += abs($value);
                                    $genetic_effect_sum_square_altered_env_5 = $genetic_effect_sum_square_altered_env_5 + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_gen_row_count++;
                    }
                close($fh);

                open(my $fh_2dspl, '<', $stats_out_tempfile_2dspl) or die "Could not open file '$stats_out_tempfile_2dspl' $!";
                    print STDERR "Opened $stats_out_tempfile_2dspl\n";

                    my $header_2dspl = <$fh_2dspl>;
                    my @header_cols_2dspl;
                    if ($csv->parse($header_2dspl)) {
                        @header_cols_2dspl = $csv->fields();
                    }
                    shift @header_cols_2dspl;
                    while (my $row_2dspl = <$fh_2dspl>) {
                        my @columns;
                        if ($csv->parse($row_2dspl)) {
                            @columns = $csv->fields();
                        }
                        my $col_counter = 0;
                        foreach my $encoded_trait (@header_cols_2dspl) {
                            if ($encoded_trait eq $t) {
                                my $trait = $trait_name_encoder_rev{$encoded_trait};
                                my $plot_id = $columns[0];

                                my $plot_name = $plot_id_map{$plot_id};
                                my $value = $columns[$col_counter+1];
                                if (defined $value && $value ne '') {
                                    $result_blup_spatial_data_altered_env_5->{$plot_name}->{$trait} = [$value, $timestamp, $user_name, '', ''];

                                    if ($value < $env_effect_min_altered_env_5) {
                                        $env_effect_min_altered_env_5 = $value;
                                    }
                                    elsif ($value >= $env_effect_max_altered_env_5) {
                                        $env_effect_max_altered_env_5 = $value;
                                    }

                                    $env_effect_sum_altered_env_5 += abs($value);
                                    $env_effect_sum_square_altered_env_5 = $env_effect_sum_square_altered_env_5 + $value*$value;
                                }
                            }
                            $col_counter++;
                        }
                        $current_env_row_count++;
                    }
                close($fh_2dspl);

                open(my $fh_residual, '<', $stats_out_tempfile_residual) or die "Could not open file '$stats_out_tempfile_residual' $!";
                    print STDERR "Opened $stats_out_tempfile_residual\n";

                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $trait_name = $trait_name_encoder_rev{$t};
                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_5->{$stock_name}->{$trait_name} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_5 += abs($residual);
                            $residual_sum_square_altered_env_5 = $residual_sum_square_altered_env_5 + $residual*$residual;
                        }
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_5->{$stock_name}->{$trait_name} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_5 = $model_sum_square_residual_altered_env_5 + $residual*$residual;
                    }
                close($fh_residual);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    elsif ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {

        print STDERR Dumper $statistics_cmd;
        my $status_r = system($statistics_cmd);

        my @pheno_var;
        open(my $fh_r, '<', $stats_out_param_tempfile)
            or die "Could not open file '$stats_out_param_tempfile' $!";
            print STDERR "Opened $stats_out_param_tempfile\n";

            while (defined(my $row = <$fh_r>)) {
                my @columns;
                if ($csv->parse($row)) {
                    @columns = $csv->fields();
                }
                push @pheno_var, \@columns;
            }
        close($fh_r);
        # print STDERR Dumper \@pheno_var;

        my $stats_tempfile_2_basename = basename($stats_tempfile_2);
        my $grm_file_basename = basename($grm_rename_tempfile);
        my $permanent_environment_structure_file_basename = basename($permanent_environment_structure_tempfile);
        my $permanent_environment_structure_env_file_basename = basename($permanent_environment_structure_env_tempfile_mat);
        #my @phenotype_header = ("id", "plot_id", "replicate", "time", "replicate_time", "ind_replicate", @sorted_trait_names, "phenotype");

        my $effect_1_levels = scalar(@rep_time_factors);
        my $effect_grm_levels = scalar(@unique_accession_names);
        my $effect_pe_levels = scalar(@ind_rep_factors);

        my @param_file_rows = (
            'DATAFILE',
            $stats_tempfile_2_basename,
            'NUMBER_OF_TRAITS',
            '1',
            'NUMBER_OF_EFFECTS',
            ($legendre_order_number + 1)*2 + 1,
            'OBSERVATION(S)',
            $legendre_order_number + 1 + 6 + 1,
            'WEIGHT(S)',
            '',
            'EFFECTS: POSITION_IN_DATAFILE NUMBER_OF_LEVELS TYPE_OF_EFFECT',
            '5 '.$effect_1_levels.' cross',
        );
        my $p_counter = 1;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p_counter.' '.$effect_grm_levels.' cov 1';
            $p_counter++;
        }
        my $p2_counter = 1;
        my @hetres_group;
        foreach (0 .. $legendre_order_number) {
            push @param_file_rows, 6+$p2_counter.' '.$effect_pe_levels.' cov 6';
            push @hetres_group, 6+$p2_counter;
            $p2_counter++;
        }
        my @random_group1;
        foreach (1..$legendre_order_number+1) {
            push @random_group1, 1+$_;
        }
        my $random_group_string1 = join ' ', @random_group1;
        my @random_group2;
        foreach (1..$legendre_order_number+1) {
            push @random_group2, 1+scalar(@random_group1)+$_;
        }
        my $random_group_string2 = join ' ', @random_group2;
        my $hetres_group_string = join ' ', @hetres_group;
        push @param_file_rows, (
            'RANDOM_RESIDUAL VALUES',
            '1',
            'RANDOM_GROUP',
            $random_group_string1,
            'RANDOM_TYPE',
            'user_file_inv',
            'FILE',
            $grm_file_basename,
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        push @param_file_rows, (
            'RANDOM_GROUP',
            $random_group_string2,
            'RANDOM_TYPE'
        );

        if ($permanent_environment_structure eq 'identity') {
            push @param_file_rows, (
                'diagonal',
                'FILE',
                ''
            );
        }
        elsif ($permanent_environment_structure eq 'env_corr_structure') {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_env_file_basename
            );
        }
        else {
            push @param_file_rows, (
                'user_file_inv',
                'FILE',
                $permanent_environment_structure_file_basename
            );
        }

        push @param_file_rows, (
            '(CO)VARIANCES'
        );
        foreach (@pheno_var) {
            my $s = join ' ', @$_;
            push @param_file_rows, $s;
        }
        my $hetres_pol_string = join ' ', @sorted_scaled_ln_times;
        push @param_file_rows, (
            'OPTION hetres_pos '.$hetres_group_string,
            'OPTION hetres_pol '.$hetres_pol_string,
            'OPTION conv_crit '.$tolparinv,
            'OPTION residual',
        );

        open(my $Fp, ">", $parameter_tempfile) || die "Can't open file ".$parameter_tempfile;
            foreach (@param_file_rows) {
                print $Fp "$_\n";
            }
        close($Fp);

        print STDERR Dumper $cmd_f90;
        my $status = system($cmd_f90);

        open(my $fh_log, '<', $stats_out_tempfile)
            or die "Could not open file '$stats_out_tempfile' $!";
    
            print STDERR "Opened $stats_out_tempfile\n";
            while (my $row = <$fh_log>) {
                print STDERR $row;
            }
        close($fh_log);

        my $q_time = "SELECT t.cvterm_id FROM cvterm as t JOIN cv ON(t.cv_id=cv.cv_id) WHERE t.name=? and cv.name=?;";
        my $h_time = $schema->storage->dbh()->prepare($q_time);

        $yhat_residual_tempfile = $tmp_stats_dir."/yhat_residual";
        open(my $fh_yhat_res, '<', $yhat_residual_tempfile) or die "Could not open file '$yhat_residual_tempfile' $!";
            print STDERR "Opened $yhat_residual_tempfile\n";

            my $pred_res_counter = 0;
            my $trait_counter = 0;
            while (my $row = <$fh_yhat_res>) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $pred = $vals[0];
                my $residual = $vals[1];
                $model_sum_square_residual_altered_env_5 = $model_sum_square_residual_altered_env_5 + $residual*$residual;

                my $plot_name = $plot_id_count_map_reverse{$pred_res_counter};
                my $time = $time_count_map_reverse{$pred_res_counter};

                if (defined $residual && $residual ne '') {
                    $result_residual_data_altered_env_5->{$plot_name}->{$seen_times{$time}} = [$residual, $timestamp, $user_name, '', ''];
                    $residual_sum_altered_env_5 += abs($residual);
                    $residual_sum_square_altered_env_5 = $residual_sum_square_altered_env_5 + $residual*$residual;
                }
                if (defined $pred && $pred ne '') {
                    $result_fitted_data_altered_env_5->{$plot_name}->{$seen_times{$time}} = [$pred, $timestamp, $user_name, '', ''];
                }

                $pred_res_counter++;
            }
        close($fh_yhat_res);

        $blupf90_solutions_tempfile = $tmp_stats_dir."/solutions";
        open(my $fh_sol, '<', $blupf90_solutions_tempfile) or die "Could not open file '$blupf90_solutions_tempfile' $!";
            print STDERR "Opened $blupf90_solutions_tempfile\n";

            my $head = <$fh_sol>;
            print STDERR $head;

            my $solution_file_counter = 0;
            my $grm_sol_counter = 0;
            my $grm_sol_trait_counter = 0;
            my $pe_sol_counter = 0;
            my $pe_sol_trait_counter = 0;
            while (defined(my $row = <$fh_sol>)) {
                # print STDERR $row;
                my @vals = split ' ', $row;
                my $level = $vals[2];
                my $value = $vals[3];
                if ($solution_file_counter < $effect_1_levels) {
                    $fixed_effects_altered_env_5{$solution_file_counter}->{$level} = $value;
                }
                elsif ($solution_file_counter < $effect_1_levels + $effect_grm_levels*($legendre_order_number+1)) {
                    my $accession_name = $accession_id_factor_map_reverse{$level};
                    if ($grm_sol_counter < $effect_grm_levels-1) {
                        $grm_sol_counter++;
                    }
                    else {
                        $grm_sol_counter = 0;
                        $grm_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_genetic_coefficients_altered_env_5{$accession_name}}, $value;
                    }
                }
                else {
                    my $plot_name = $plot_id_factor_map_reverse{$level};
                    if ($pe_sol_counter < $effect_pe_levels-1) {
                        $pe_sol_counter++;
                    }
                    else {
                        $pe_sol_counter = 0;
                        $pe_sol_trait_counter++;
                    }
                    if (defined $value && $value ne '') {
                        push @{$rr_temporal_coefficients_altered_env_5{$plot_name}}, $value;
                    }
                }
                $solution_file_counter++;
            }
        close($fh_sol);

        # print STDERR Dumper \%rr_genetic_coefficients_altered;
        # print STDERR Dumper \%rr_temporal_coefficients_altered;

        open(my $Fgc, ">", $coeff_genetic_tempfile) || die "Can't open file ".$coeff_genetic_tempfile;

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env_5) {
            my @line = ($accession_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fgc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_blup = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_data_altered_env_5->{$accession_name}->{$time_term_string_blup} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fgc);

        while ( my ($accession_name, $coeffs) = each %rr_genetic_coefficients_altered_env_5) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                $result_blup_data_delta_altered_env_5->{$accession_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];

                if ($value < $genetic_effect_min_altered_env_5) {
                    $genetic_effect_min_altered_env_5 = $value;
                }
                elsif ($value >= $genetic_effect_max_altered_env_5) {
                    $genetic_effect_max_altered_env_5 = $value;
                }

                $genetic_effect_sum_altered_env_5 += abs($value);
                $genetic_effect_sum_square_altered_env_5 = $genetic_effect_sum_square_altered_env_5 + $value*$value;
            }
        }

        open(my $Fpc, ">", $coeff_pe_tempfile) || die "Can't open file ".$coeff_pe_tempfile;

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env_5) {
            my @line = ($plot_name, @$coeffs);
            my $line_string = join ',', @line;
            print $Fpc "$line_string\n";

            foreach my $t_i (0..20) {
                my $time = $t_i*5/100;
                my $time_rescaled = sprintf("%.2f", $time*($time_max - $time_min) + $time_min);

                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }

                my $time_term_string = '';
                if ($statistics_select eq 'blupf90_grm_random_regression_gdd_blups' || $statistics_select eq 'airemlf90_grm_random_regression_gdd_blups') {
                    $time_term_string = "GDD $time_rescaled";
                }
                elsif ($statistics_select eq 'blupf90_grm_random_regression_dap_blups' || $statistics_select eq 'airemlf90_grm_random_regression_dap_blups') {
                    $time_term_string = "day $time_rescaled"
                }
                $h_time->execute($time_term_string, 'cxgn_time_ontology');
                my ($time_cvterm_id) = $h_time->fetchrow_array();

                if (!$time_cvterm_id) {
                    my $new_time_term = $schema->resultset("Cv::Cvterm")->create_with({
                       name => $time_term_string,
                       cv => 'cxgn_time_ontology'
                    });
                    $time_cvterm_id = $new_time_term->cvterm_id();
                }
                my $time_term_string_pe = SGN::Model::Cvterm::get_trait_from_cvterm_id($schema, $time_cvterm_id, 'extended');

                $result_blup_pe_data_altered_env_5->{$plot_name}->{$time_term_string_pe} = [$value, $timestamp, $user_name, '', ''];
            }
        }
        close($Fpc);

        while ( my ($plot_name, $coeffs) = each %rr_temporal_coefficients_altered_env_5) {
            foreach my $time_term (@sorted_trait_names) {
                my $time = ($time_term - $time_min)/($time_max - $time_min);
                my $value = 0;
                my $coeff_counter = 0;
                foreach my $b (@$coeffs) {
                    my $eval_string = $legendre_coeff_exec[$coeff_counter];
                    # print STDERR Dumper [$eval_string, $b, $time];
                    $value += eval $eval_string;
                    $coeff_counter++;
                }
    
                $result_blup_pe_data_delta_altered_env_5->{$plot_name}->{$time_term} = [$value, $timestamp, $user_name, '', ''];
    
                if ($value < $env_effect_min_altered_env_5) {
                    $env_effect_min_altered_env_5 = $value;
                }
                elsif ($value >= $env_effect_max_altered_env_5) {
                    $env_effect_max_altered_env_5 = $value;
                }
    
                $env_effect_sum_altered_env_5 += abs($value);
                $env_effect_sum_square_altered_env_5 = $env_effect_sum_square_altered_env_5 + $value*$value;
            }
        }
    }
    elsif ($statistics_select eq 'asreml_grm_univariate_spatial_genetic_blups') {
        foreach my $t (@sorted_trait_names) {

            $statistics_cmd = 'R -e "library(asreml); library(data.table); library(reshape2);
            mat <- data.frame(fread(\''.$stats_tempfile_2.'\', header=TRUE, sep=\',\'));
            geno_mat_3col <- data.frame(fread(\''.$grm_rename_tempfile.'\', header=FALSE, sep=\' \'));
            mat\$rowNumber <- as.numeric(mat\$rowNumber);
            mat\$colNumber <- as.numeric(mat\$colNumber);
            mat\$rowNumberFactor <- as.factor(mat\$rowNumber);
            mat\$colNumberFactor <- as.factor(mat\$colNumber);
            mat\$id_factor <- as.factor(mat\$id_factor);
            mat <- mat[order(mat\$rowNumber, mat\$colNumber),];
            attr(geno_mat_3col,\'rowNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'colNames\') <- as.character(seq(1,'.$number_accessions.'));
            attr(geno_mat_3col,\'INVERSE\') <- TRUE;
            mix <- asreml(t'.$t.'~1 + replicate, random=~vm(id_factor, geno_mat_3col) + ar1(rowNumberFactor):ar1v(colNumberFactor), residual=~idv(units), data=mat);
            if (!is.null(summary(mix,coef=TRUE)\$coef.random)) {
            write.table(summary(mix,coef=TRUE)\$coef.random, file=\''.$stats_out_tempfile.'\', row.names=TRUE, col.names=TRUE, sep=\'\t\');
            write.table(data.frame(plot_id = mat\$plot_id, residuals = mix\$residuals, fitted = mix\$linear.predictors), file=\''.$stats_out_tempfile_residual.'\', row.names=FALSE, col.names=TRUE, sep=\'\t\');
            }
            "';
            print STDERR Dumper $statistics_cmd;
            eval {
                my $status = system($statistics_cmd);
            };

            my $run_stats_fault = 0;
            if ($@) {
                print STDERR "R ERROR\n";
                print STDERR Dumper $@;
                $run_stats_fault = 1;
            }
            else {
                my $current_gen_row_count = 0;
                my $current_env_row_count = 0;
                my @row_col_ordered_plots_names;

                open(my $fh_residual, '<', $stats_out_tempfile_residual)
                    or die "Could not open file '$stats_out_tempfile_residual' $!";
                
                    print STDERR "Opened $stats_out_tempfile_residual\n";
                    my $header_residual = <$fh_residual>;
                    my @header_cols_residual;
                    if ($csv->parse($header_residual)) {
                        @header_cols_residual = $csv->fields();
                    }
                    while (my $row = <$fh_residual>) {
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }

                        my $stock_id = $columns[0];
                        my $residual = $columns[1];
                        my $fitted = $columns[2];
                        my $stock_name = $plot_id_map{$stock_id};
                        push @row_col_ordered_plots_names, $stock_name;
                        if (defined $residual && $residual ne '') {
                            $result_residual_data_altered_env_5->{$stock_name}->{$t} = [$residual, $timestamp, $user_name, '', ''];
                            $residual_sum_altered_env_5 += abs($residual);
                            $residual_sum_square_altered_env_5 = $residual_sum_square_altered_env_5 + $residual*$residual;}
                        if (defined $fitted && $fitted ne '') {
                            $result_fitted_data_altered_env_5->{$stock_name}->{$t} = [$fitted, $timestamp, $user_name, '', ''];
                        }
                        $model_sum_square_residual_altered_env_5 = $model_sum_square_residual_altered_env_5 + $residual*$residual;
                    }
                close($fh_residual);

                open(my $fh, '<', $stats_out_tempfile) or die "Could not open file '$stats_out_tempfile' $!";
                    print STDERR "Opened $stats_out_tempfile\n";
                    my $header = <$fh>;

                    my $solution_file_counter = 0;
                    while (defined(my $row = <$fh>)) {
                        # print STDERR $row;
                        my @columns;
                        if ($csv->parse($row)) {
                            @columns = $csv->fields();
                        }
                        my $level = $columns[0];
                        my $value = $columns[1];
                        my $std = $columns[2];
                        my $z_ratio = $columns[3];
                        if (defined $value && $value ne '') {
                            if ($solution_file_counter < $number_accessions) {
                                my $stock_name = $accession_id_factor_map_reverse{$solution_file_counter+1};
                                $result_blup_data_altered_env_5->{$stock_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $genetic_effect_min_altered_env_5) {
                                    $genetic_effect_min_altered_env_5 = $value;
                                }
                                elsif ($value >= $genetic_effect_max_altered_env_5) {
                                    $genetic_effect_max_altered_env_5 = $value;
                                }

                                $genetic_effect_sum_altered_env_5 += abs($value);
                                $genetic_effect_sum_square_altered_env_5 = $genetic_effect_sum_square_altered_env_5 + $value*$value;

                                $current_gen_row_count++;
                            }
                            else {
                                my $plot_name = $row_col_ordered_plots_names[$current_env_row_count-$number_accessions];
                                $result_blup_spatial_data_altered_env_5->{$plot_name}->{$t} = [$value, $timestamp, $user_name, '', ''];

                                if ($value < $env_effect_min_altered_env_5) {
                                    $env_effect_min_altered_env_5 = $value;
                                }
                                elsif ($value >= $env_effect_max_altered_env_5) {
                                    $env_effect_max_altered_env_5 = $value;
                                }

                                $env_effect_sum_altered_env_5 += abs($value);
                                $env_effect_sum_square_altered_env_5 = $env_effect_sum_square_altered_env_5 + $value*$value;

                                $current_env_row_count++;
                            }
                        }
                        $solution_file_counter++;
                    }
                close($fh);

                if ($current_env_row_count == 0 || $current_gen_row_count == 0) {
                    $run_stats_fault = 1;
                }

                if ($run_stats_fault == 1) {
                    $c->stash->{rest} = {error=>'Error in R! Try a larger tolerance'};
                    $c->detach();
                    print STDERR "ERROR IN R CMD\n";
                }
            }
        }
    }
    print STDERR "ALTERED w/SIM_ENV ar1xar1 $statistics_select GENETIC EFFECT SUM $genetic_effect_sum_altered_env_5\n";
    print STDERR "ALTERED w/SIM_ENV ar1xar1 $statistics_select ENV EFFECT SUM $env_effect_sum_altered_env_5\n";
    print STDERR Dumper [$genetic_effect_min_altered_env_5, $genetic_effect_max_altered_env_5, $env_effect_min_altered_env_5, $env_effect_max_altered_env_5];

    return ($statistical_ontology_term, $analysis_model_training_data_file_type, $analysis_model_language, \@sorted_residual_trait_names, \%rr_unique_traits, \%rr_residual_unique_traits, $statistics_cmd, $cmd_f90, $number_traits, \%trait_to_time_map,
    
    $result_blup_data_original, $result_blup_data_delta_original, $result_blup_spatial_data_original, $result_blup_pe_data_original, $result_blup_pe_data_delta_original, $result_residual_data_original, $result_fitted_data_original, \%fixed_effects_original, \%rr_genetic_coefficients_original, \%rr_temporal_coefficients_original,
    
    $model_sum_square_residual_original, $genetic_effect_min_original, $genetic_effect_max_original, $env_effect_min_original, $env_effect_max_original, $genetic_effect_sum_square_original, $genetic_effect_sum_original, $env_effect_sum_square_original, $env_effect_sum_original, $residual_sum_square_original, $residual_sum_original,
    
    \%phenotype_data_altered, \@data_matrix_altered, \@data_matrix_phenotypes_altered, $phenotype_min_altered, $phenotype_max_altered,
    
    $result_blup_data_altered, $result_blup_data_delta_altered, $result_blup_spatial_data_altered, $result_blup_pe_data_altered, $result_blup_pe_data_delta_altered, $result_residual_data_altered, $result_fitted_data_altered, \%fixed_effects_altered, \%rr_genetic_coefficients_altered, \%rr_temporal_coefficients_altered,
    
    $model_sum_square_residual_altered, $genetic_effect_min_altered, $genetic_effect_max_altered, $env_effect_min_altered, $env_effect_max_altered, $genetic_effect_sum_square_altered, $genetic_effect_sum_altered, $env_effect_sum_square_altered, $env_effect_sum_altered, $residual_sum_square_altered, $residual_sum_altered,
    
    \%phenotype_data_altered_env, \@data_matrix_altered_env, \@data_matrix_phenotypes_altered_env, $phenotype_min_altered_env, $phenotype_max_altered_env, $env_sim_min, $env_sim_max, \%sim_data,
    
    $result_blup_data_altered_env, $result_blup_data_delta_altered_env, $result_blup_spatial_data_altered_env, $result_blup_pe_data_altered_env, $result_blup_pe_data_delta_altered_env, $result_residual_data_altered_env, $result_fitted_data_altered_env, \%fixed_effects_altered_env, \%rr_genetic_coefficients_altered_env, \%rr_temporal_coefficients_altered_env,
    
    $model_sum_square_residual_altered_env, $genetic_effect_min_altered_env, $genetic_effect_max_altered_env, $env_effect_min_altered_env, $env_effect_max_altered_env, $genetic_effect_sum_square_altered_env, $genetic_effect_sum_altered_env, $env_effect_sum_square_altered_env, $env_effect_sum_altered_env, $residual_sum_square_altered_env, $residual_sum_altered_env,
    
    \%phenotype_data_altered_env_2, \@data_matrix_altered_env_2, \@data_matrix_phenotypes_altered_env_2, $phenotype_min_altered_env_2, $phenotype_max_altered_env_2, $env_sim_min_2, $env_sim_max_2, \%sim_data_2,
    
    $result_blup_data_altered_env_2, $result_blup_data_delta_altered_env_2, $result_blup_spatial_data_altered_env_2, $result_blup_pe_data_altered_env_2, $result_blup_pe_data_delta_altered_env_2, $result_residual_data_altered_env_2, $result_fitted_data_altered_env_2, \%fixed_effects_altered_env_2, \%rr_genetic_coefficients_altered_env_2, \%rr_temporal_coefficients_altered_env_2,

    $model_sum_square_residual_altered_env_2, $genetic_effect_min_altered_env_2, $genetic_effect_max_altered_env_2, $env_effect_min_altered_env_2, $env_effect_max_altered_env_2, $genetic_effect_sum_square_altered_env_2, $genetic_effect_sum_altered_env_2, $env_effect_sum_square_altered_env_2, $env_effect_sum_altered_env_2, $residual_sum_square_altered_env_2, $residual_sum_altered_env_2,
    
    \%phenotype_data_altered_env_3, \@data_matrix_altered_env_3, \@data_matrix_phenotypes_altered_env_3, $phenotype_min_altered_env_3, $phenotype_max_altered_env_3, $env_sim_min_3, $env_sim_max_3, \%sim_data_3,
    
    $result_blup_data_altered_env_3, $result_blup_data_delta_altered_env_3, $result_blup_spatial_data_altered_env_3, $result_blup_pe_data_altered_env_3, $result_blup_pe_data_delta_altered_env_3, $result_residual_data_altered_env_3, $result_fitted_data_altered_env_3, \%fixed_effects_altered_env_3, \%rr_genetic_coefficients_altered_env_3, \%rr_temporal_coefficients_altered_env_3,
    
    $model_sum_square_residual_altered_env_3, $genetic_effect_min_altered_env_3, $genetic_effect_max_altered_env_3, $env_effect_min_altered_env_3, $env_effect_max_altered_env_3, $genetic_effect_sum_square_altered_env_3, $genetic_effect_sum_altered_env_3, $env_effect_sum_square_altered_env_3, $env_effect_sum_altered_env_3, $residual_sum_square_altered_env_3, $residual_sum_altered_env_3,
    
    \%phenotype_data_altered_env_4, \@data_matrix_altered_env_4, \@data_matrix_phenotypes_altered_env_4, $phenotype_min_altered_env_4, $phenotype_max_altered_env_4, $env_sim_min_4, $env_sim_max_4, \%sim_data_4,
    
    $result_blup_data_altered_env_4, $result_blup_data_delta_altered_env_4, $result_blup_spatial_data_altered_env_4, $result_blup_pe_data_altered_env_4, $result_blup_pe_data_delta_altered_env_4, $result_residual_data_altered_env_4, $result_fitted_data_altered_env_4, \%fixed_effects_altered_env_4, \%rr_genetic_coefficients_altered_env_4, \%rr_temporal_coefficients_altered_env_4,

    $model_sum_square_residual_altered_env_4, $genetic_effect_min_altered_env_4, $genetic_effect_max_altered_env_4, $env_effect_min_altered_env_4, $env_effect_max_altered_env_4, $genetic_effect_sum_square_altered_env_4, $genetic_effect_sum_altered_env_4, $env_effect_sum_square_altered_env_4, $env_effect_sum_altered_env_4, $residual_sum_square_altered_env_4, $residual_sum_altered_env_4,
    
    \%phenotype_data_altered_env_5, \@data_matrix_altered_env_5, \@data_matrix_phenotypes_altered_env_5, $phenotype_min_altered_env_5, $phenotype_max_altered_env_5, $env_sim_min_5, $env_sim_max_5, \%sim_data_5,
    
    $result_blup_data_altered_env_5, $result_blup_data_delta_altered_env_5, $result_blup_spatial_data_altered_env_5, $result_blup_pe_data_altered_env_5, $result_blup_pe_data_delta_altered_env_5, $result_residual_data_altered_env_5, $result_fitted_data_altered_env_5, \%fixed_effects_altered_env_5, \%rr_genetic_coefficients_altered_env_5, \%rr_temporal_coefficients_altered_env_5,

    $model_sum_square_residual_altered_env_5, $genetic_effect_min_altered_env_5, $genetic_effect_max_altered_env_5, $env_effect_min_altered_env_5, $env_effect_max_altered_env_5, $genetic_effect_sum_square_altered_env_5, $genetic_effect_sum_altered_env_5, $env_effect_sum_square_altered_env_5, $env_effect_sum_altered_env_5, $residual_sum_square_altered_env_5, $residual_sum_altered_env_5
    );
}

sub _check_user_login {
    my $c = shift;
    my $role_check = shift;
    my $user_id;
    my $user_name;
    my $user_role;
    my $session_id = $c->req->param("sgn_session_id");

    if ($session_id){
        my $dbh = $c->dbc->dbh;
        my @user_info = CXGN::Login->new($dbh)->query_from_cookie($session_id);
        if (!$user_info[0]){
            $c->stash->{rest} = {error=>'You must be logged in to do this!'};
            $c->detach();
        }
        $user_id = $user_info[0];
        $user_role = $user_info[1];
        my $p = CXGN::People::Person->new($dbh, $user_id);
        $user_name = $p->get_username;
    } else{
        if (!$c->user){
            $c->stash->{rest} = {error=>'You must be logged in to do this!'};
            $c->detach();
        }
        $user_id = $c->user()->get_object()->get_sp_person_id();
        $user_name = $c->user()->get_object()->get_username();
        $user_role = $c->user->get_object->get_user_type();
    }
    if ($role_check && $user_role ne $role_check) {
        $c->stash->{rest} = {error=>'You must have permission to do this! Please contact us!'};
        $c->detach();
    }
    return ($user_id, $user_name, $user_role);
}

1;
