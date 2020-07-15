#!/usr/bin/env perl


=head1 NAME

 SeedlotQualityNSource.pm

=head1 SYNOPSIS

mx-run SeedlotQualityNSource.pm [options] -H hostname -D dbname -u username [-F]

this is a subclass of L<CXGN::Metadata::Dbpatch>
see the perldoc of parent class for more details.

=head1 DESCRIPTION

This is a test dummy patch.
This subclass uses L<Moose>. The parent class uses L<MooseX::Runnable>

=head1 AUTHOR

 Naama Menda<nm249@cornell.edu>

=head1 COPYRIGHT & LICENSE

Copyright 2010 Boyce Thompson Institute for Plant Research

This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut


package SeedlotQualityNSource;

use Moose;
use Bio::Chado::Schema;

extends 'CXGN::Metadata::Dbpatch';


has '+description' => ( default => ' This patch adds required stock prop types for seedlot quality.');

has '+prereq' => (
    default => sub {
        [ ],
    },
  );

sub patch {
    my $self=shift;

    print STDOUT "Executing the patch:\n " .   $self->name . ".\n\nDescription:\n  ".  $self->description . ".\n\nExecuted by:\n " .  $self->username . " .";

    print STDOUT "\nChecking if this db_patch was executed before or if previous db_patches have been executed.\n";

    print STDOUT "\nExecuting the SQL commands.\n";

     my $schema = Bio::Chado::Schema->connect( sub { $self->dbh->clone } );

    $schema->resultset("Cv::Cvterm")->create_with(
	{
	    name => 'seedlot_quality',
	    cv => 'stock_property'
	});


    print STDERR "Done!\n";
}


####
1; #
####
