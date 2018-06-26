package CXGN::BrAPI::FileRequest;

=head1 NAME

CXGN::BrAPI::FileRequest - an object to handle creating and archiving files for BrAPI requests that store data .

=head1 SYNOPSIS

this module is used to create and archive files for BrAPI requests that store data. It stores the file on fileserver and saves the file to a user, allowing them to access it later on.

=head1 AUTHORS

=cut

use Moose;
use Data::Dumper;
use File::Spec::Functions;
use DateTime;

has 'schema' => (
    isa => 'Bio::Chado::Schema',
    is => 'rw',
    required => 1,
);

has 'user_id' => (
    is => 'ro',
    isa => 'Int',
    required => 1,
);

has 'user_type' => (
    is => 'ro',
    isa => 'Str',
    required => 1,
);

has 'format' => (
	isa => 'Str',
	is => 'rw',
	required => 1,
);

has 'archive_path' => (
    isa => "Str",
    is => 'rw',
    required => 1,
);

has 'data' => (
	isa => 'ArrayRef',
	is => 'rw',
	required => 1,
);

sub BUILD {
	my $self = shift;
	my $format = $self->format;
	if ($format ne 'Fieldbook'){
		die "format must be Fieldbook\n";
	}
}

sub get_path {
	my $self = shift;
	my $format = $self->format;
	if ($format eq 'Fieldbook'){
		return $self->fieldbook;
	}
}

sub fieldbook {
	my $self = shift;
	my $data = $self->data;
    my $user_id = $self->user_id;
    my $user_type = $self->user_type;
    my $archive_path = $self->archive_path;

    #check that user type is adequate to archive file

    my $subdirectory = "brapi_observations_upload";
    my $archive_filename = "test_file";

    if (!-d $archive_path) {
        mkdir $archive_path;
    }

    if (! -d catfile($archive_path, $user_id)) {
        mkdir (catfile($archive_path, $user_id));
    }

    if (! -d catfile($archive_path, $user_id,$subdirectory)) {
        mkdir (catfile($archive_path, $user_id, $subdirectory));
    }

    my $time = DateTime->now();
    my $timestamp = $time->ymd()."_".$time->hms();
    my $file_path =  catfile($archive_path, $user_id, $subdirectory,$timestamp."_".$archive_filename);

    print STDERR "File path is: $file_path\n";

    my @data = @{$data};

    # print STDERR "First plot is: ".Dumper($first_plot)."\n";
    # print STDERR "First plot id is: ".$first_plot->{'observationUnitDbId'}."\n";

	# my $num_col = scalar(keys %{$data[0]});
    # print STDERR "Num cols: $num_col\n";

	open(my $fh, ">", $file_path);
    print $fh '"plot_id","trait","value","timestamp","person"'."\n";
		foreach my $plot (@data){

            my $uniquename = $self->schema->resultset('Stock::Stock')->find({'stock_id' => $plot->{'observationUnitDbId'}})->uniquename();

            print $fh "\"$uniquename\"," || "\"\",";
            print $fh "\"|$plot->{'observationVariableDbId'}\"," || "\"\",";
            print $fh "\"$plot->{'value'}\"," || "\"\",";
            print $fh "\"$plot->{'observationTimeStamp'}\"," || "\"\",";
            print $fh "\"$plot->{'collector'}\"" || "\"\"";
            print $fh "\n";
            #
			# my $step = 1;
			# for(my $i=0; $i<$num_col; $i++) {
			# 	if ($cols->[$i]) {
			# 		print $fh "\"$cols->[$i]\"";
			# 	} else {
			# 		print $fh "\"\"";
			# 	}
			# 	if ($step < $num_col) {
			# 		print $fh ",";
			# 	}
			# 	$step++;
			# }
			# print $fh "\n";
		}
	close $fh;

	return $file_path;
}

1;
