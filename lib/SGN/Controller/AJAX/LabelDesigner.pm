
=head1 NAME

=head1 DESCRIPTION

=head1 AUTHOR

=cut

package SGN::Controller::AJAX::LabelDesigner;

use Moose;
use CXGN::Stock;
use Data::Dumper;
use Try::Tiny;
use JSON;
use Barcode::Code128;
use PDF::API2;
use Sort::Versions;
use Tie::UrlEncoder; our(%urlencode);

BEGIN { extends 'Catalyst::Controller::REST' }

__PACKAGE__->config(
    default   => 'application/json',
    stash_key => 'rest',
    map       => { 'application/json' => 'JSON', 'text/html' => 'JSON' },
   );

   sub retrieve_longest_fields :Path('/tools/label_designer/retrieve_longest_fields') {
       my $self = shift;
       my $c = shift;
       my $schema = $c->dbic_schema('Bio::Chado::Schema');
       my $uri     = URI::Encode->new( { encode_reserved => 0 } );
       my $trial_id = $uri->decode($c->req->param("trial_id"));
       my %longest_hash;

       # get trial details
       my $trial_name = $schema->resultset("Project::Project")->search({ project_id => $trial_id })->first->name();
       if (!$trial_name) {
           $c->stash->{rest} = { error => "Trial with id $trial_id does not exist. Can't create labels." };
           return;
       }
       $longest_hash{'trial_name'} = $trial_name;

       my $design = CXGN::Trial::TrialLayout->new({schema => $schema, trial_id => $trial_id })->get_design();
       my %design = %{$design};
       if (!%design) {
           $c->stash->{rest} = { error => "Trial $trial_name does not have a valid field design. Can't create labels." };
           return;
       }

       my $year_cvterm_id = $schema->resultset("Cv::Cvterm")->search({name=> 'project year' })->first->cvterm_id();
       my $year = $schema->resultset("Project::Projectprop")->search({ project_id => $trial_id, type_id => $year_cvterm_id } )->first->value();
       $longest_hash{'year'} = $year;


       #get all fields in this trials design
       my $random_plot = $design{(keys %design)[rand keys %design]};
       my @keys = keys %{$random_plot};
       foreach my $field (@keys) {
           print STDERR " Searching for longest $field\n";
           #for each field order values by descending length, then save the first one
           foreach my $key ( sort { length($design{$b}{$field}) <=> length($design{$a}{$field}) or  $a <=> $b } keys %design) {
                print STDERR "Longest $field is: ".$design{$key}{$field}."\n";
                my $longest = $design{$key}{$field};
                unless (ref($longest) || length($longest) < 1) { # skip if not scalar or undefined
                    $longest_hash{$field} = $design{$key}{$field};
                }
                last;
            }
        }

        # save longest pedigree string
        my $pedigree_strings = get_all_pedigrees($schema, \%design);
        my %pedigree_strings = %{$pedigree_strings};

        foreach my $key ( sort { length($pedigree_strings{$b}) <=> length($pedigree_strings{$a}) } keys %pedigree_strings) {
            $longest_hash{'pedigree_string'} = $pedigree_strings{$key};
            last;
        }

        #print STDERR "Dumped data is: ".Dumper(%longest_hash);
        $c->stash->{rest} = \%longest_hash;
   }

   sub label_designer_download : Path('/tools/label_designer/download') : ActionClass('REST') { }

   sub label_designer_download_GET : Args(0) {
        my $self = shift;
        my $c = shift;
        $c->forward('label_designer_download_POST');
    }

  sub label_designer_download_POST : Args(0) {
       my $self = shift;
       my $c = shift;
       my $schema = $c->dbic_schema('Bio::Chado::Schema');
       my $type = $c->req->param("type");
       my $trial_id = $c->req->param("trial_id");
       my $design_json = $c->req->param("design_json");
       my $dots_to_pixels_conversion_factor = 2.83; # for converting from 8 dots per mmm to 2.83 per mm (72 per inch)

       # decode json
       my $json = new JSON;
       my $design_params = $json->allow_nonref->utf8->relaxed->escape_slash->loose->allow_singlequote->allow_barekey->decode($design_json);

       # get trial details
       my $trial_name = $schema->resultset("Project::Project")->search({ project_id => $trial_id })->first->name();
       if (!$trial_name) {
           $c->stash->{rest} = { error => "Trial with id $trial_id does not exist. Can't create labels." };
           return;
       }

       my $design = CXGN::Trial::TrialLayout->new({schema => $schema, trial_id => $trial_id })->get_design();
       my %design = %{$design};
       if (!$design) {
           $c->stash->{rest} = { error => "Trial $trial_name does not have a valid field design. Can't create labels." };
           return;
       }

       my $year_cvterm_id = $schema->resultset("Cv::Cvterm")->search({name=> 'project year' })->first->cvterm_id();
       my $year = $schema->resultset("Project::Projectprop")->search({ project_id => $trial_id, type_id => $year_cvterm_id } )->first->value();

       my $label_params = $design_params->{'label_elements'};
       # if needed retrieve pedigrees in bulk
       my $pedigree_strings;
       foreach my $element (@$label_params) {
           if ($element->{'value'} eq '{pedigree_string}') {
               $pedigree_strings = get_all_pedigrees($schema, $design);
           }
       }

       # Create a blank PDF file
       my $dir = $c->tempfiles_subdir('labels');
       my $file_prefix = $trial_name;
       $file_prefix =~ s/[^a-zA-Z0-9-_]//g;
       my ($FH, $filename) = $c->tempfile(TEMPLATE=>"labels/$file_prefix-XXXXX", SUFFIX=>".$type");

       # initialize loop variables
       my $col_num = 1;
       my $row_num = 1;
       my $key_number = 0;
       my $sort_order = $design_params->{'sort_order'};

       if ($type eq 'pdf') {
           # Create pdf
           my $pdf  = PDF::API2->new(-file => $FH);
           my $page = $pdf->page();
           my $text = $page->text();
           my $gfx = $page->gfx();
           $page->mediabox($design_params->{'page_width'}, $design_params->{'page_height'});

           # loop through plot data in design hash
           foreach my $key ( sort { versioncmp( $design{$a}{$sort_order} , $design{$b}{$sort_order} ) or  $a <=> $b } keys %design) {

                print STDERR "Design key is $key\n";
                my %design_info = %{$design{$key}};
                $design_info{'trial_name'} = $trial_name;
                $design_info{'year'} = $year;
                $design_info{'pedigree_string'} = $pedigree_strings->{$design_info{'accession_name'}};
                print STDERR "Design info: " . Dumper(%design_info);

                for (my $i=0; $i < $design_params->{'copies_per_plot'}; $i++) {
                    #print STDERR "Working on label num $i\n";
                    my $label_x = $design_params->{'left_margin'} + ($design_params->{'label_width'} + $design_params->{'horizontal_gap'}) * ($col_num-1);
                    my $label_y = $design_params->{'page_height'} - $design_params->{'top_margin'} - ($design_params->{'label_height'} + $design_params->{'vertical_gap'}) * ($row_num-1);

                   foreach my $element (@$label_params) {
                       #print STDERR "Element Dumper\n" . Dumper($element);
                       my %element = %{$element};
                       my $elementx = $label_x + ( $element{'x'} / $dots_to_pixels_conversion_factor );
                       my $elementy = $label_y - ( $element{'y'} / $dots_to_pixels_conversion_factor );

                       my $filled_value = $element{'value'};
                       $filled_value =~ s/\{(.*?)\}/process_field($1,$key_number,\%design_info)/ge;
                       #print STDERR "Element ".$element{'type'}."_".$element{'size'}." filled value is ".$filled_value." and coords are $elementx and $elementy\n";

                       if ( $element{'type'} eq "Code128" || $element{'type'} eq "QRCode" ) {

                            if ( $element{'type'} eq "Code128" ) {

                               my $barcode_object = Barcode::Code128->new();

                               my ($png_location, $png_uri) = $c->tempfile( TEMPLATE => [ 'barcode', 'bc-XXXXX'], SUFFIX=>'.png');
                               open(PNG, ">", $png_location) or die "Can't write $png_location: $!\n";
                               binmode(PNG);

                               $barcode_object->option("scale", $element{'size'}, "font_align", "center", "padding", 5, "show_text", 0);
                               $barcode_object->barcode($filled_value);
                               my $barcode = $barcode_object->gd_image();
                               print PNG $barcode->png();
                               close(PNG);

                                my $image = $pdf->image_png($png_location);
                                my $height = $element{'height'} / $dots_to_pixels_conversion_factor ; # scale to 72 pts per inch
                                my $width = $element{'width'} / $dots_to_pixels_conversion_factor ; # scale to 72 pts per inch
                                my $elementy = $elementy - $height; # adjust for img position sarting at bottom
                                print STDERR 'adding Code 128 params $image, $elementx, $elementy, $width, $height with: '."$image, $elementx, $elementy, $width, $height\n";
                                $gfx->image($image, $elementx, $elementy, $width, $height);


                          } else { #QRCode

                              my ($jpeg_location, $jpeg_uri) = $c->tempfile( TEMPLATE => [ 'barcode', 'bc-XXXXX'], SUFFIX=>'.jpg');
                              my $barcode_generator = CXGN::QRcode->new();
                              my $barcode_file = $barcode_generator->get_barcode_file( $jpeg_location, $filled_value, $element{'size'} );

                               my $image = $pdf->image_jpeg($jpeg_location);
                               my $height = $element{'height'} / $dots_to_pixels_conversion_factor ; # scale to 72 pts per inch
                               my $width = $element{'width'} / $dots_to_pixels_conversion_factor ; # scale to 72 pts per inch
                               my $elementy = $elementy - $height; # adjust for img position sarting at bottom
                               $gfx->image($image, $elementx, $elementy, $width, $height);

                          }
                       }
                       else { #Text

                            my $font = $pdf->corefont($element{'font'}); # Add a built-in font to the PDF
                            # Add text to the page
                            my $adjusted_size = $element{'size'} / $dots_to_pixels_conversion_factor; # scale to 72 pts per inch
                            $text->font($font, $adjusted_size);
                            my $midpoint= ($element{'height'} / $dots_to_pixels_conversion_factor ) / 2;
                            my $elementy = $elementy - $midpoint; # adjust for position starting at middle
                            $text->translate($elementx, $elementy);
                            $text->text($filled_value);
                       }
                   }

                    if ($col_num < $design_params->{'number_of_columns'}) { #next column
                        $col_num++;
                    } else { #new row, reset col num
                        $col_num = 1;
                        $row_num++;
                    }

                    if ($row_num > $design_params->{'number_of_rows'}) { #create new page and reset row and col num
                        $pdf->finishobjects($page, $gfx, $text); #flush the page to save memory on big PDFs
                        $page = $pdf->page();
                        $text = $page->text();
                        $gfx = $page->gfx();
                        $page->mediabox($design_params->{'page_width'}, $design_params->{'page_height'});
                        $row_num = 1;
                    }
                }
             $key_number++;
             }

           print STDERR "Saving the PDF . . .\n";
           $pdf->save();

       } elsif ($type eq 'zpl') {
           # do zpl conversion
           my $label_params = label_params_to_zpl($label_params, $design_params->{'label_width'}, $design_params->{'label_height'});

           foreach my $key ( sort { versioncmp( $design{$a}{$sort_order} , $design{$b}{$sort_order} ) or  $a <=> $b } keys %design) {

               print STDERR "Design key is $key\n";
               my %design_info = %{$design{$key}};
               $design_info{'trial_name'} = $trial_name;
               $design_info{'year'} = $year;
               $design_info{'pedigree_string'} = $pedigree_strings->{$design_info{'accession_name'}};
               print STDERR "Design info: " . Dumper(%design_info);

              for (my $i=0; $i < $design_params->{'copies_per_plot'}; $i++) {
                  $label_params =~ s/\{(.*?)\}/process_field($1,$key_number,\%design_info)/ge;
                  print $FH $label_params;

               }
            $key_number++;
            }
       }

       close($FH);
       print STDERR "Returning with filename . . .\n";
       $c->stash->{rest} = { filename => $urlencode{$filename} };

   }

sub label_params_to_zpl {
    my $label_params_ref = shift;
    my @label_params = @{$label_params_ref};

    my $label_width = shift;
    my $label_height = shift;
    my $pixels_to_dots_conversion_factor = 2.83;
    $label_width = $label_width * $pixels_to_dots_conversion_factor;
    $label_height = $label_height * $pixels_to_dots_conversion_factor;

    my $zpl = "^XA\n^LL$label_height^PW$label_width\n";
    foreach my $element (@label_params) {
        my %element = %$element;
        $zpl .= "^FO$element{'x'},$element{'y'}";
        if ( $element{'type'} eq "Code128" ) {
            my $height = $element{'size'} * 25;
            $zpl .= "^BY$element{'size'}^BCN,$height,N,N,N^FD   $element{'value'}^FS\n";
        } elsif ( $element{'type'} eq "QRCode" ) {
            $zpl .= "^BQ,,$element{'size'}^FD   $element{'value'}^FS\n";
        } else {
            $zpl .= "^AA,$element{'size'}^FD$element{'value'}^FS\n";
        }
    }
    $zpl .= "^XZ\n";
    print STDERR "ZPL is $zpl\n";
    return $zpl
}

sub process_field {
    my $field = shift;
    my $key_number = shift;
    my $design_info = shift;
    my %design_info = %{$design_info};
    print STDERR "Field is $field\n";
    if ($field =~ m/Number:/) {
        our ($placeholder, $start_num, $increment) = split ':', $field;
        my $length = length($start_num);
        #print STDERR "Increment is $increment\nKey Number is $key_number\n";
        my $custom_num =  $start_num + ($increment * $key_number);
        return sprintf("%0${length}d", $custom_num);
    } else {
        return $design_info{$field};
    }
}

sub get_all_pedigrees {
    my $schema = shift;
    my $design = shift;
    my %design = %{$design};

    # collect all unique accession ids for pedigree retrieval
    my %accession_id_hash;
    foreach my $key (keys %design) {
        $accession_id_hash{$design{$key}{'accession_id'}} = $design{$key}{'accession_name'};
    }
    my @accession_ids = keys %accession_id_hash;

    # retrieve pedigree info using batch download (fastest method), then extract pedigree strings from download rows.
    my $stock = CXGN::Stock->new ( schema => $schema);
    my $pedigree_rows = $stock->get_pedigree_rows(\@accession_ids, 'parents_only');
    my %pedigree_strings;
    foreach my $row (@$pedigree_rows) {
        my ($progeny, $female_parent, $male_parent, $type) = split "\t", $row;
        my $string = join ('/', $female_parent ? $female_parent : 'NA', $male_parent ? $male_parent : 'NA');
        $pedigree_strings{$progeny} = $string;
    }
    return \%pedigree_strings;
}


#########
1;
#########
