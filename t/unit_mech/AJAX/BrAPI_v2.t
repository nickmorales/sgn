
use strict;
use warnings;

#use lib 't/lib';
#use SGN::Test::Fixture;
use Test::More;
use Test::WWW::Mechanize;
use LWP::UserAgent;

#Needed to update IO::Socket::SSL
use Data::Dumper;
use JSON;
local $Data::Dumper::Indent = 0;

my $mech = Test::WWW::Mechanize->new;
my $ua   = LWP::UserAgent->new;
my $response; my $searchId; my $resp; my $data;

$mech->get_ok('http://localhost:3010/brapi/v2/serverinfo');
$response = decode_json $mech->content;
print STERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::ServerInfo'},{'messageType' => 'INFO','message' => 'Calls result constructed'}],'datafiles' => [],'pagination' => {'totalPages' => 1,'currentPage' => 0,'totalCount' => 116,'pageSize' => 1000}},'result' => {'calls' => [{'service' => 'serverinfo','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'versions' => ['2.0'],'methods' => ['GET'],'datatypes' => ['application/json'],'service' => 'commoncropnames'},{'datatypes' => ['application/json'],'service' => 'lists','versions' => ['2.0'],'methods' => ['GET','POST']},{'versions' => ['2.0'],'methods' => ['GET','PUT'],'datatypes' => ['application/json'],'service' => 'lists/{listDbId}'},{'methods' => ['POST'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'lists/{listDbId}/items'},{'service' => 'search/lists','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['POST']},{'service' => 'search/lists/{searchResultsDbId}','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'service' => 'locations','datatypes' => ['application/json'],'methods' => ['GET','POST'],'versions' => ['2.0']},{'service' => 'locations/{locationDbId}','datatypes' => ['application/json'],'methods' => ['GET','PUT'],'versions' => ['2.0']},{'versions' => ['2.0'],'methods' => ['POST'],'datatypes' => ['application/json'],'service' => 'search/locations'},{'methods' => ['GET'],'versions' => ['2.0'],'service' => 'search/locations/{searchResultsDbId}','datatypes' => ['application/json']},{'datatypes' => ['application/json'],'service' => 'people','versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'people/{peopleDbId}','versions' => ['2.0'],'methods' => ['GET']},{'versions' => ['2.0'],'methods' => ['POST'],'datatypes' => ['application/json'],'service' => 'search/people'},{'datatypes' => ['application/json'],'service' => 'search/people/{searchResultsDbId}','methods' => ['GET'],'versions' => ['2.0']},{'methods' => ['GET','POST'],'versions' => ['2.0'],'service' => 'programs','datatypes' => ['application/json']},{'datatypes' => ['application/json'],'service' => 'programs/{programDbId}','versions' => ['2.0'],'methods' => ['GET','PUT']},{'versions' => ['2.0'],'methods' => ['POST'],'service' => 'search/programs','datatypes' => ['application/json']},{'datatypes' => ['application/json'],'service' => 'search/programs/{searchResultsDbId}','methods' => ['GET'],'versions' => ['2.0']},{'datatypes' => ['application/json'],'service' => 'seasons','versions' => ['2.0'],'methods' => ['GET']},{'methods' => ['GET'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'seasons/{seasonDbId}'},{'service' => 'search/seasons','datatypes' => ['application/json'],'methods' => ['POST'],'versions' => ['2.0']},{'datatypes' => ['application/json'],'service' => 'search/seasons/{searchResultsDbId}','versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'studies','methods' => ['GET','POST'],'versions' => ['2.0']},{'versions' => ['2.0'],'methods' => ['GET','PUT'],'datatypes' => ['application/json'],'service' => 'studies/{studyDbId}'},{'methods' => ['POST'],'versions' => ['2.0'],'service' => 'search/studies','datatypes' => ['application/json']},{'versions' => ['2.0'],'methods' => ['GET'],'datatypes' => ['application/json'],'service' => 'search/studies/{searchResultsDbId}'},{'service' => 'studytypes','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'datatypes' => ['application/json'],'service' => 'trials','versions' => ['2.0'],'methods' => ['GET','POST']},{'datatypes' => ['application/json'],'service' => 'trials/{trialDbId}','versions' => ['2.0'],'methods' => ['GET','PUT']},{'datatypes' => ['application/json'],'service' => 'search/trials','methods' => ['POST'],'versions' => ['2.0']},{'service' => 'search/trials/{searchResultsDbId}','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'images','versions' => ['2.0'],'methods' => ['GET','POST']},{'methods' => ['GET','PUT'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'images/{imageDbId}'},{'service' => 'images/{imageDbId}/imagecontent','datatypes' => ['application/json'],'methods' => ['PUT'],'versions' => ['2.0']},{'datatypes' => ['application/json'],'service' => 'search/images','versions' => ['2.0'],'methods' => ['POST']},{'datatypes' => ['application/json'],'service' => 'search/images/{searchResultsDbId}','versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'observations','versions' => ['2.0'],'methods' => ['GET','POST','PUT']},{'methods' => ['GET','PUT'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'observations/{observationDbId}'},{'service' => 'observations/table','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'search/observations','methods' => ['POST'],'versions' => ['2.0']},{'datatypes' => ['application/json'],'service' => 'search/observations/{searchResultsDbId}','methods' => ['GET'],'versions' => ['2.0']},{'service' => 'observationlevels','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'methods' => ['GET','POST','PUT'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'observationunits'},{'methods' => ['GET','PUT'],'versions' => ['2.0'],'service' => 'observationunits/{observationUnitDbId}','datatypes' => ['application/json']},{'datatypes' => ['application/json'],'service' => 'search/observationunits','versions' => ['2.0'],'methods' => ['POST']},{'service' => 'search/observationunits/{searchResultsDbId}','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'service' => 'ontologies','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'service' => 'traits','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'datatypes' => ['application/json'],'service' => 'traits/{traitDbId}','versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'variables','versions' => ['2.0'],'methods' => ['GET']},{'methods' => ['GET'],'versions' => ['2.0'],'service' => 'variables/{observationVariableDbId}','datatypes' => ['application/json']},{'datatypes' => ['application/json'],'service' => 'search/variables','methods' => ['POST'],'versions' => ['2.0']},{'service' => 'search/variables/{searchResultsDbId}','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'methods' => ['GET'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'calls'},{'versions' => ['2.0'],'methods' => ['POST'],'service' => 'search/calls','datatypes' => ['application/json']},{'versions' => ['2.0'],'methods' => ['GET'],'service' => 'search/calls/{searchResultsDbId}','datatypes' => ['application/json']},{'service' => 'callsets','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'methods' => ['GET'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'callsets/{callSetDbId}'},{'datatypes' => ['application/json'],'service' => 'callsets/{callSetDbId}/calls','versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'search/callsets','versions' => ['2.0'],'methods' => ['POST']},{'datatypes' => ['application/json'],'service' => 'search/callsets/{searchResultsDbId}','versions' => ['2.0'],'methods' => ['GET']},{'service' => 'maps','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'versions' => ['2.0'],'methods' => ['GET'],'service' => 'maps/{mapDbId}','datatypes' => ['application/json']},{'datatypes' => ['application/json'],'service' => 'maps/{mapDbId}/linkagegroups','versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'markerpositions','versions' => ['2.0'],'methods' => ['GET']},{'versions' => ['2.0'],'methods' => ['POST'],'datatypes' => ['application/json'],'service' => 'search/markerpositions'},{'service' => 'search/markerpositions/{searchResultsDbId}','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'versions' => ['2.0'],'methods' => ['GET'],'service' => 'references','datatypes' => ['application/json']},{'methods' => ['GET'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'references/{referenceDbId}'},{'versions' => ['2.0'],'methods' => ['POST'],'service' => 'search/references','datatypes' => ['application/json']},{'versions' => ['2.0'],'methods' => ['GET'],'datatypes' => ['application/json'],'service' => 'search/references/{searchResultsDbId}'},{'service' => 'referencesets','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'methods' => ['GET'],'versions' => ['2.0'],'service' => 'referencesets/{referenceSetDbId}','datatypes' => ['application/json']},{'service' => 'search/referencesets','datatypes' => ['application/json'],'methods' => ['POST'],'versions' => ['2.0']},{'datatypes' => ['application/json'],'service' => 'search/referencesets/{searchResultsDbId}','methods' => ['GET'],'versions' => ['2.0']},{'service' => 'samples','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'service' => 'samples/{sampleDbId}','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'versions' => ['2.0'],'methods' => ['POST'],'datatypes' => ['application/json'],'service' => 'search/samples'},{'datatypes' => ['application/json'],'service' => 'search/samples/{searchResultsDbId}','methods' => ['GET'],'versions' => ['2.0']},{'datatypes' => ['application/json'],'service' => 'variants','versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'variants/{variantDbId}','methods' => ['GET'],'versions' => ['2.0']},{'service' => 'variants/{variantDbId}/calls','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'versions' => ['2.0'],'methods' => ['POST'],'service' => 'search/variants','datatypes' => ['application/json']},{'service' => 'search/variants/{searchResultsDbId}','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'variantsets','versions' => ['2.0'],'methods' => ['GET']},{'datatypes' => ['application/json'],'service' => 'variantsets/extract','methods' => ['GET'],'versions' => ['2.0']},{'versions' => ['2.0'],'methods' => ['GET'],'service' => 'variantsets/{variantSetDbId}','datatypes' => ['application/json']},{'versions' => ['2.0'],'methods' => ['GET'],'service' => 'variantsets/{variantSetDbId}/calls','datatypes' => ['application/json']},{'methods' => ['GET'],'versions' => ['2.0'],'service' => 'variantsets/{variantSetDbId}/callsets','datatypes' => ['application/json']},{'methods' => ['GET'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'variantsets/{variantSetDbId}/variants'},{'methods' => ['POST'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'search/variantsets'},{'service' => 'search/variantsets/{searchResultsDbId}','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'versions' => ['2.0'],'methods' => ['GET','POST'],'datatypes' => ['application/json'],'service' => 'germplasm'},{'versions' => ['2.0'],'methods' => ['GET','PUT'],'datatypes' => ['application/json'],'service' => 'germplasm/{germplasmDbId}'},{'versions' => ['2.0'],'methods' => ['GET'],'service' => 'germplasm/{germplasmDbId}/pedigree','datatypes' => ['application/json']},{'methods' => ['GET'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'germplasm/{germplasmDbId}/progeny'},{'service' => 'germplasm/{germplasmDbId}/mcpd','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']},{'versions' => ['2.0'],'methods' => ['POST'],'datatypes' => ['application/json'],'service' => 'search/germplasm'},{'versions' => ['2.0'],'methods' => ['GET'],'service' => 'search/germplasm/{searchResultsDbId}','datatypes' => ['application/json']},{'service' => 'attributes','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'methods' => ['GET'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'attributes/categories'},{'methods' => ['GET'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'attributes/{attributeDbId}'},{'datatypes' => ['application/json'],'service' => 'search/attributes','versions' => ['2.0'],'methods' => ['POST']},{'versions' => ['2.0'],'methods' => ['GET'],'datatypes' => ['application/json'],'service' => 'search/attributes/{searchResultsDbId}'},{'methods' => ['GET'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'attributevalues'},{'service' => 'attributevalues/{attributeValueDbId}','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'methods' => ['POST'],'versions' => ['2.0'],'datatypes' => ['application/json'],'service' => 'search/attributevalues'},{'service' => 'search/attributevalues/{searchResultsDbId}','datatypes' => ['application/json'],'methods' => ['GET'],'versions' => ['2.0']},{'service' => 'crossingprojects','datatypes' => ['application/json'],'methods' => ['GET','POST'],'versions' => ['2.0']},{'methods' => ['GET','PUT'],'versions' => ['2.0'],'service' => 'crossingprojects/{crossingProjectDbId}','datatypes' => ['application/json']},{'versions' => ['2.0'],'methods' => ['GET','POST'],'service' => 'crosses','datatypes' => ['application/json']},{'versions' => ['2.0'],'methods' => ['GET','POST'],'service' => 'seedlots','datatypes' => ['application/json']},{'versions' => ['2.0'],'methods' => ['GET','POST'],'datatypes' => ['application/json'],'service' => 'seedlots/transactions'},{'versions' => ['2.0'],'methods' => ['GET','PUT'],'service' => 'seedlots/{seedLotDbId}','datatypes' => ['application/json']},{'service' => 'seedlots/{seedLotDbId}/transactions','datatypes' => ['application/json'],'versions' => ['2.0'],'methods' => ['GET']}],'serverName' => 'localhost','organizationURL' => 'http://localhost:3010/','permissions' => {'PUT' => 'curator','POST' => 'curator','GET' => 'any'},'location' => 'USA','organizationName' => 'Boyce Thompson Institute','contactEmail' => 'lam87@cornell.edu','documentationURL' => 'https://solgenomics.github.io/sgn/','serverDescription' => 'BrAPI v2.0 compliant server'}});
$mech->post_ok('http://localhost:3010/brapi/v2/token', [ "username"=> "janedoe", "password"=> "secretpw", "grant_type"=> "password" ]);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is($response->{'metadata'}->{'status'}->[2]->{'message'}, 'Login Successfull');
is($response->{'userDisplayName'}, 'Jane Doe');
is($response->{'expires_in'}, '7200');

$mech->delete_ok('http://localhost:3010/brapi/v2/token');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is($response->{'metadata'}->{'status'}->[2]->{'message'}, 'User Logged Out');

$mech->post_ok('http://localhost:3010/brapi/v2/token', [ "username"=> "janedoe", "password"=> "secretpw", "grant_type"=> "password" ]);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is($response->{'metadata'}->{'status'}->[2]->{'message'}, 'Login Successfull');
is($response->{'userDisplayName'}, 'Jane Doe');
is($response->{'expires_in'}, '7200');
my $access_token = $response->{access_token};

$ua->default_header("Content-Type" => "application/json");
$ua->default_header('Authorization'=> 'Bearer ' . $access_token);
$mech->default_header("Content-Type" => "application/json");
$mech->default_header('Authorization'=> 'Bearer ' . $access_token);

# Phenotyping

$mech->get_ok('http://localhost:3010/brapi/v2/observationlevels');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'levelName' => 'replicate','levelOrder' => 0},{'levelName' => 'block','levelOrder' => 1},{'levelName' => 'plot','levelOrder' => 2},{'levelName' => 'subplot','levelOrder' => 3},{'levelName' => 'plant','levelOrder' => 4},{'levelName' => 'tissue_sample','levelOrder' => 5}]},'metadata' => {'pagination' => {'totalPages' => 1,'pageSize' => 6,'totalCount' => 6,'currentPage' => 0},'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::ObservationVariables'},{'messageType' => 'INFO','message' => 'Observation Levels result constructed'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/observationunits');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::ObservationUnits','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Observation Units search result constructed'}],'datafiles' => [],'pagination' => {'totalPages' => 196,'pageSize' => 10,'totalCount' => 1954,'currentPage' => 0}},'result' => {'data' => [{'observationUnitDbId' => '41284','locationDbId' => '23','locationName' => 'test_location','studyName' => 'CASS_6Genotypes_Sampling_2015','observationUnitName' => 'CASS_6Genotypes_103','trialName' => undef,'observations' => [],'additionalInfo' => {},'programDbId' => '134','germplasmName' => 'IITA-TMS-IBA980581','programName' => 'test','externalReferences' => [],'treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'observationUnitPosition' => {'positionCoordinateYType' => 'GRID_ROW','positionCoordinateX' => undef,'observationLevelRelationships' => [{'levelCode' => '1','levelName' => 'replicate','levelOrder' => 0},{'levelOrder' => 1,'levelName' => 'block','levelCode' => '1'},{'levelName' => 'plot','levelCode' => '103','levelOrder' => 2},{'levelCode' => undef,'levelName' => 'plant','levelOrder' => 4}],'observationLevel' => {'levelCode' => '103','levelName' => 'plot','levelOrder' => 2},'positionCoordinateY' => undef,'entryType' => 'test','positionCoordinateXType' => 'GRID_COL','geoCoordinates' => ''},'germplasmDbId' => '41283','trialDbId' => '','studyDbId' => '165','observationUnitPUI' => '103'},{'programName' => 'test','externalReferences' => [],'observationUnitPosition' => {'positionCoordinateYType' => 'GRID_ROW','positionCoordinateX' => undef,'observationLevelRelationships' => [{'levelCode' => '1','levelName' => 'replicate','levelOrder' => 0},{'levelOrder' => 1,'levelCode' => '1','levelName' => 'block'},{'levelCode' => '104','levelName' => 'plot','levelOrder' => 2},{'levelOrder' => 4,'levelName' => 'plant','levelCode' => undef}],'geoCoordinates' => '','observationLevel' => {'levelName' => 'plot','levelCode' => '104','levelOrder' => 2},'positionCoordinateY' => undef,'entryType' => 'test','positionCoordinateXType' => 'GRID_COL'},'treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'trialDbId' => '','germplasmDbId' => '41282','studyDbId' => '165','observationUnitPUI' => '104','observationUnitDbId' => '41295','locationName' => 'test_location','locationDbId' => '23','observationUnitName' => 'CASS_6Genotypes_104','studyName' => 'CASS_6Genotypes_Sampling_2015','programDbId' => '134','germplasmName' => 'IITA-TMS-IBA980002','observations' => [],'trialName' => undef,'additionalInfo' => {}},{'programName' => 'test','externalReferences' => [],'observationUnitPosition' => {'observationLevel' => {'levelName' => 'plot','levelCode' => '105','levelOrder' => 2},'positionCoordinateXType' => 'GRID_COL','positionCoordinateY' => undef,'entryType' => 'test','geoCoordinates' => '','positionCoordinateX' => undef,'positionCoordinateYType' => 'GRID_ROW','observationLevelRelationships' => [{'levelOrder' => 0,'levelCode' => '1','levelName' => 'replicate'},{'levelName' => 'block','levelCode' => '1','levelOrder' => 1},{'levelName' => 'plot','levelCode' => '105','levelOrder' => 2},{'levelOrder' => 4,'levelCode' => undef,'levelName' => 'plant'}]},'treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'germplasmDbId' => '41279','trialDbId' => '','studyDbId' => '165','observationUnitPUI' => '105','observationUnitDbId' => '41296','locationName' => 'test_location','locationDbId' => '23','observationUnitName' => 'CASS_6Genotypes_105','studyName' => 'CASS_6Genotypes_Sampling_2015','observations' => [],'trialName' => undef,'additionalInfo' => {},'programDbId' => '134','germplasmName' => 'IITA-TMS-IBA30572'},{'observationUnitDbId' => '41297','locationDbId' => '23','locationName' => 'test_location','studyName' => 'CASS_6Genotypes_Sampling_2015','observationUnitName' => 'CASS_6Genotypes_106','additionalInfo' => {},'observations' => [],'trialName' => undef,'germplasmName' => 'IITA-TMS-IBA011412','programDbId' => '134','programName' => 'test','observationUnitPosition' => {'observationLevelRelationships' => [{'levelName' => 'replicate','levelCode' => '1','levelOrder' => 0},{'levelName' => 'block','levelCode' => '1','levelOrder' => 1},{'levelName' => 'plot','levelCode' => '106','levelOrder' => 2},{'levelOrder' => 4,'levelCode' => undef,'levelName' => 'plant'}],'positionCoordinateX' => undef,'positionCoordinateYType' => 'GRID_ROW','geoCoordinates' => '','positionCoordinateXType' => 'GRID_COL','positionCoordinateY' => undef,'entryType' => 'test','observationLevel' => {'levelCode' => '106','levelName' => 'plot','levelOrder' => 2}},'treatments' => [{'factor' => 'No ManagementFactor','modality' => ''}],'externalReferences' => [],'germplasmDbId' => '41281','trialDbId' => '','observationUnitPUI' => '106','studyDbId' => '165'},{'studyDbId' => '165','observationUnitPUI' => '107','germplasmDbId' => '41280','trialDbId' => '','externalReferences' => [],'treatments' => [{'factor' => 'No ManagementFactor','modality' => ''}],'observationUnitPosition' => {'geoCoordinates' => '','observationLevel' => {'levelName' => 'plot','levelCode' => '107','levelOrder' => 2},'entryType' => 'test','positionCoordinateY' => undef,'positionCoordinateXType' => 'GRID_COL','positionCoordinateYType' => 'GRID_ROW','positionCoordinateX' => undef,'observationLevelRelationships' => [{'levelName' => 'replicate','levelCode' => '1','levelOrder' => 0},{'levelName' => 'block','levelCode' => '1','levelOrder' => 1},{'levelCode' => '107','levelName' => 'plot','levelOrder' => 2},{'levelOrder' => 4,'levelCode' => undef,'levelName' => 'plant'}]},'programName' => 'test','trialName' => undef,'observations' => [],'additionalInfo' => {},'germplasmName' => 'TMEB693','programDbId' => '134','observationUnitName' => 'CASS_6Genotypes_107','studyName' => 'CASS_6Genotypes_Sampling_2015','locationName' => 'test_location','locationDbId' => '23','observationUnitDbId' => '41298'},{'trialName' => undef,'observations' => [],'additionalInfo' => {},'programDbId' => '134','germplasmName' => 'BLANK','studyName' => 'CASS_6Genotypes_Sampling_2015','observationUnitName' => 'CASS_6Genotypes_201','locationDbId' => '23','locationName' => 'test_location','observationUnitDbId' => '41299','studyDbId' => '165','observationUnitPUI' => '201','germplasmDbId' => '40326','trialDbId' => '','externalReferences' => [],'observationUnitPosition' => {'positionCoordinateX' => undef,'positionCoordinateYType' => 'GRID_ROW','observationLevelRelationships' => [{'levelOrder' => 0,'levelName' => 'replicate','levelCode' => '1'},{'levelName' => 'block','levelCode' => '2','levelOrder' => 1},{'levelOrder' => 2,'levelName' => 'plot','levelCode' => '201'},{'levelName' => 'plant','levelCode' => undef,'levelOrder' => 4}],'geoCoordinates' => '','observationLevel' => {'levelName' => 'plot','levelCode' => '201','levelOrder' => 2},'positionCoordinateXType' => 'GRID_COL','entryType' => 'test','positionCoordinateY' => undef},'treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'programName' => 'test'},{'observationUnitPosition' => {'observationLevelRelationships' => [{'levelName' => 'replicate','levelCode' => '1','levelOrder' => 0},{'levelOrder' => 1,'levelName' => 'block','levelCode' => '2'},{'levelCode' => '202','levelName' => 'plot','levelOrder' => 2},{'levelName' => 'plant','levelCode' => undef,'levelOrder' => 4}],'positionCoordinateX' => undef,'positionCoordinateYType' => 'GRID_ROW','positionCoordinateXType' => 'GRID_COL','entryType' => 'test','positionCoordinateY' => undef,'observationLevel' => {'levelCode' => '202','levelName' => 'plot','levelOrder' => 2},'geoCoordinates' => ''},'treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'externalReferences' => [],'programName' => 'test','observationUnitPUI' => '202','studyDbId' => '165','germplasmDbId' => '41280','trialDbId' => '','locationDbId' => '23','locationName' => 'test_location','observationUnitDbId' => '41300','additionalInfo' => {},'observations' => [],'trialName' => undef,'programDbId' => '134','germplasmName' => 'TMEB693','studyName' => 'CASS_6Genotypes_Sampling_2015','observationUnitName' => 'CASS_6Genotypes_202'},{'locationDbId' => '23','locationName' => 'test_location','observationUnitDbId' => '41301','germplasmName' => 'IITA-TMS-IBA980002','programDbId' => '134','additionalInfo' => {},'trialName' => undef,'observations' => [],'observationUnitName' => 'CASS_6Genotypes_203','studyName' => 'CASS_6Genotypes_Sampling_2015','treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'observationUnitPosition' => {'geoCoordinates' => '','observationLevel' => {'levelOrder' => 2,'levelCode' => '203','levelName' => 'plot'},'positionCoordinateXType' => 'GRID_COL','positionCoordinateY' => undef,'entryType' => 'test','positionCoordinateX' => undef,'positionCoordinateYType' => 'GRID_ROW','observationLevelRelationships' => [{'levelOrder' => 0,'levelName' => 'replicate','levelCode' => '1'},{'levelCode' => '2','levelName' => 'block','levelOrder' => 1},{'levelOrder' => 2,'levelCode' => '203','levelName' => 'plot'},{'levelOrder' => 4,'levelName' => 'plant','levelCode' => undef}]},'externalReferences' => [],'programName' => 'test','observationUnitPUI' => '203','studyDbId' => '165','trialDbId' => '','germplasmDbId' => '41282'},{'observationUnitPUI' => '204','studyDbId' => '165','trialDbId' => '','germplasmDbId' => '41283','treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'observationUnitPosition' => {'positionCoordinateYType' => 'GRID_ROW','positionCoordinateX' => undef,'observationLevelRelationships' => [{'levelOrder' => 0,'levelName' => 'replicate','levelCode' => '1'},{'levelOrder' => 1,'levelName' => 'block','levelCode' => '2'},{'levelCode' => '204','levelName' => 'plot','levelOrder' => 2},{'levelOrder' => 4,'levelName' => 'plant','levelCode' => undef}],'observationLevel' => {'levelName' => 'plot','levelCode' => '204','levelOrder' => 2},'positionCoordinateY' => undef,'entryType' => 'test','positionCoordinateXType' => 'GRID_COL','geoCoordinates' => ''},'externalReferences' => [],'programName' => 'test','germplasmName' => 'IITA-TMS-IBA980581','programDbId' => '134','additionalInfo' => {},'trialName' => undef,'observations' => [],'studyName' => 'CASS_6Genotypes_Sampling_2015','observationUnitName' => 'CASS_6Genotypes_204','locationDbId' => '23','locationName' => 'test_location','observationUnitDbId' => '41302'},{'observationUnitDbId' => '41285','locationName' => 'test_location','locationDbId' => '23','observationUnitName' => 'CASS_6Genotypes_205','studyName' => 'CASS_6Genotypes_Sampling_2015','germplasmName' => 'IITA-TMS-IBA011412','programDbId' => '134','additionalInfo' => {},'observations' => [],'trialName' => undef,'programName' => 'test','treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'observationUnitPosition' => {'observationLevelRelationships' => [{'levelCode' => '1','levelName' => 'replicate','levelOrder' => 0},{'levelCode' => '2','levelName' => 'block','levelOrder' => 1},{'levelOrder' => 2,'levelName' => 'plot','levelCode' => '205'},{'levelName' => 'plant','levelCode' => undef,'levelOrder' => 4}],'positionCoordinateYType' => 'GRID_ROW','positionCoordinateX' => undef,'geoCoordinates' => '','positionCoordinateY' => undef,'entryType' => 'test','positionCoordinateXType' => 'GRID_COL','observationLevel' => {'levelOrder' => 2,'levelName' => 'plot','levelCode' => '205'}},'externalReferences' => [],'trialDbId' => '','germplasmDbId' => '41281','observationUnitPUI' => '205','studyDbId' => '165'}]}});


$data = '[{ "additionalInfo": {"control": 1 },"germplasmDbId": "41281","germplasmName": "IITA-TMS-IBA011412","locationDbId": "23","locationName": "test_location","observationUnitName": "Testing Plot","observationUnitPUI": "10","programDbId": "134","programName": "test","seedLotDbId": "","studyDbId": "165","studyName": "CASS_6Genotypes_Sampling_2015","treatments": [],"trialDbId": "165","trialName": "","observationUnitPosition": {"entryType": "TEST","geoCoordinates": {"geometry": {  "coordinates": [-76.506042,42.417373,155  ],  "type": "Point"},"type": "Feature"},"observationLevel": {"levelName": "plot","levelOrder": 2,"levelCode": "10"},"observationLevelRelationships": [{  "levelCode": "Field_1",  "levelName": "field",  "levelOrder": 0},{  "levelCode": "Block_12",  "levelName": "block",  "levelOrder": 1},{  "levelCode": "Plot_123",  "levelName": "plot",  "levelOrder": 2}],"positionCoordinateX": "74","positionCoordinateXType": "GRID_COL","positionCoordinateY": "03","positionCoordinateYType": "GRID_ROW"} }]';
$mech->post('http://localhost:3010/brapi/v2/observationunits/', Content => $data);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => '','metadata' => {'datafiles' => undef,'pagination' => {'totalPages' => 1,'pageSize' => 10,'totalCount' => 1,'currentPage' => 0},'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::ObservationUnits'},{'message' => 'Observation Units have been added','messageType' => 'INFO'}]}} );

$mech->get_ok('http://localhost:3010/brapi/v2/observationunits/41782');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'pageSize' => 10,'totalCount' => 1,'currentPage' => 0,'totalPages' => 1},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::ObservationUnits','messageType' => 'INFO'},{'message' => 'Observation Units search result constructed','messageType' => 'INFO'}],'datafiles' => []},'result' => {'data' => [{'programName' => 'test','programDbId' => '134','studyName' => 'CASS_6Genotypes_Sampling_2015','studyDbId' => '165','locationDbId' => '23','treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'germplasmDbId' => '41281','observationUnitPosition' => {'geoCoordinates' => '','positionCoordinateY' => '03','observationLevel' => {'levelName' => 'plot','levelCode' => '','levelOrder' => 2},'positionCoordinateX' => '74','positionCoordinateXType' => '','observationLevelRelationships' => [{'levelName' => 'replicate','levelCode' => '1','levelOrder' => 0},{'levelName' => 'block','levelCode' => 'Block_12','levelOrder' => 1},{'levelName' => 'plot','levelCode' => '10','levelOrder' => 2},{'levelCode' => undef,'levelOrder' => 4,'levelName' => 'plant'}],'entryType' => 'check','positionCoordinateYType' => ''},'observationUnitDbId' => '41782','trialName' => undef,'locationName' => 'test_location','observationUnitName' => 'Testing Plot','additionalInfo' => {},'externalReferences' => [],'observationUnitPUI' => '10','trialDbId' => '','observations' => [],'germplasmName' => 'IITA-TMS-IBA011412'}]}});

$data = '{
  "additionalInfo": {
      "control": 1 },
  "germplasmDbId": "41281",
  "germplasmName": "IITA-TMS-IBA011412",
  "locationDbId": "23",
  "locationName": "test_location",
  "observationUnitName": "Testing Plot",
  "observationUnitPUI": "10",
  "programDbId": "134",
  "programName": "test",
  "seedLotDbId": "",
  "studyDbId": "165",
  "studyName": "CASS_6Genotypes_Sampling_2015",
  "treatments": [],
  "trialDbId": "165",
  "trialName": "",
  "observationUnitPosition": {"entryType": "TEST",
      "geoCoordinates": {
        "geometry": {
          "coordinates": [
            -76.506042,
            42.417373,
            155
          ],
          "type": "Point"
        },
        "type": "Feature"
      },
      "observationLevel": {
        "levelName": "plot",
        "levelOrder": 2,
        "levelCode": "10"
      },
      "observationLevelRelationships": [
        {
          "levelCode": "Field_1",
          "levelName": "field",
          "levelOrder": 0
        },
        {
          "levelCode": "Block_12",
          "levelName": "block",
          "levelOrder": 1
        },
        {
          "levelCode": "Plot_123",
          "levelName": "plot",
          "levelOrder": 2
        }
      ],
      "positionCoordinateX": "74",
      "positionCoordinateXType": "GRID_COL",
      "positionCoordinateY": "03",
      "positionCoordinateYType": "GRID_ROW"
      }
   }';




$resp = $ua->put("http://192.168.33.11:3010/brapi/v2/observationunits/41782", Content => $data);
$response = decode_json $resp->{_content};
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::ObservationUnits','messageType' => 'INFO'},{'message' => 'Observation Units updated','messageType' => 'INFO'}],'datafiles' => undef,'pagination' => {'totalCount' => 1,'currentPage' => 0,'pageSize' => 10,'totalPages' => 1}},'result' => ''} );

$mech->get_ok('http://localhost:3010/brapi/v2/observationunits/41782');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'treatments' => [{'factor' => 'No ManagementFactor','modality' => ''}],'trialDbId' => '','germplasmDbId' => '41281','observationUnitDbId' => '41782','programName' => 'test','germplasmName' => 'IITA-TMS-IBA011412','locationName' => 'test_location','studyName' => 'CASS_6Genotypes_Sampling_2015','observationUnitPUI' => '10','observations' => [],'observationUnitName' => 'Testing Plot','additionalInfo' => {},'studyDbId' => '165','locationDbId' => '23','trialName' => undef,'programDbId' => '134','externalReferences' => [],'observationUnitPosition' => {'positionCoordinateX' => '74','positionCoordinateXType' => '','entryType' => 'check','observationLevelRelationships' => [{'levelOrder' => 0,'levelName' => 'replicate','levelCode' => '1'},{'levelCode' => 'Block_12','levelName' => 'block','levelOrder' => 1},{'levelName' => 'plot','levelOrder' => 2,'levelCode' => '10'},{'levelName' => 'plant','levelOrder' => 4,'levelCode' => undef}],'geoCoordinates' => {'geometry' => {'type' => 'Point','coordinates' => ['-76.506042','42.417373',155]},'type' => 'Feature'},'observationLevel' => {'levelCode' => '','levelName' => 'plot','levelOrder' => 2},'positionCoordinateYType' => '','positionCoordinateY' => '03'}}]},'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::ObservationUnits'},{'message' => 'Observation Units search result constructed','messageType' => 'INFO'}],'pagination' => {'totalCount' => 1,'pageSize' => 10,'totalPages' => 1,'currentPage' => 0},'datafiles' => []}} );

$mech->get_ok('http://localhost:3010/brapi/v2/observationunits/41299?pageSize=1&page=0');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=1'},{'message' => 'Loading CXGN::BrAPI::v2::ObservationUnits','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Observation Units search result constructed'}],'datafiles' => [],'pagination' => {'totalCount' => 1,'totalPages' => 1,'currentPage' => 0,'pageSize' => 1}},'result' => {'data' => [{'observations' => [],'trialDbId' => '','observationUnitPosition' => {'geoCoordinates' => '','positionCoordinateYType' => '','positionCoordinateX' => undef,'observationLevel' => {'levelOrder' => 2,'levelCode' => '','levelName' => 'plot'},'observationLevelRelationships' => [{'levelOrder' => 0,'levelCode' => '1','levelName' => 'replicate'},{'levelCode' => '2','levelName' => 'block','levelOrder' => 1},{'levelCode' => '201','levelOrder' => 2,'levelName' => 'plot'},{'levelOrder' => 4,'levelCode' => undef,'levelName' => 'plant'}],'entryType' => 'test','positionCoordinateY' => undef,'positionCoordinateXType' => ''},'observationUnitPUI' => '201','germplasmName' => 'BLANK','externalReferences' => [],'locationName' => 'test_location','observationUnitDbId' => '41299','additionalInfo' => {},'trialName' => undef,'germplasmDbId' => '40326','studyDbId' => '165','programDbId' => '134','treatments' => [{'factor' => 'No ManagementFactor','modality' => ''}],'observationUnitName' => 'CASS_6Genotypes_201','programName' => 'test','locationDbId' => '23','studyName' => 'CASS_6Genotypes_Sampling_2015'}]}});


$data = '{
  "41300": 
	{
	"observationUnitPosition": {"entryType": "TEST",
	    "geoCoordinates": {
	      "geometry": {
	        "coordinates": [
	          -76.506042,
	          42.417373,
	          10
	        ],
	        "type": "Point"
	      },
	      "type": "Feature"
	    },
	    "observationLevel": {
	      "levelName": "plot",
	      "levelOrder": 2,
	      "levelCode": "Plot_123"
	    },
	    "observationLevelRelationships": [
	      {
	        "levelCode": "Field_1",
	        "levelName": "field",
	        "levelOrder": 0
	      },
	      {
	        "levelCode": "Block_12",
	        "levelName": "block",
	        "levelOrder": 1
	      },
	      {
	        "levelCode": "Plot_123",
	        "levelName": "plot",
	        "levelOrder": 2
	      }
	    ],
	    "positionCoordinateX": "74",
	    "positionCoordinateXType": "GRID_COL",
	    "positionCoordinateY": "03",
	    "positionCoordinateYType": "GRID_ROW"
	    }
   },
   "41301":{
		"observationUnitPosition": {"entryType": "TEST",
		    "geoCoordinates": {
		      "geometry": {
		        "coordinates": [
		          -76.506042,
		          42.417373,
		          20
		        ],
		        "type": "Point"
		      },
		      "type": "Feature"
		    },
		    "observationLevel": {
		      "levelName": "plot",
		      "levelOrder": 2,
		      "levelCode": "Plot_123"
		    },
		    "observationLevelRelationships": [
		      {
		        "levelCode": "Field_1",
		        "levelName": "field",
		        "levelOrder": 0
		      },
		      {
		        "levelCode": "Block_12",
		        "levelName": "block",
		        "levelOrder": 1
		      },
		      {
		        "levelCode": "Plot_123",
		        "levelName": "plot",
		        "levelOrder": 2
		      }
		    ],
		    "positionCoordinateX": "74",
		    "positionCoordinateXType": "GRID_COL",
		    "positionCoordinateY": "03",
		    "positionCoordinateYType": "GRID_ROW"
		    }
   }
}';
$ua->default_header("Content-Type" => "application/json");
$ua->default_header('Authorization'=> 'Bearer ' . $access_token);
$resp = $ua->put("http://192.168.33.11:3010/brapi/v2/observationunits/", Content => $data);
$response = decode_json $resp->{_content};
print STDERR Dumper $response;
is_deeply($response, {'result' => '','metadata' => {'datafiles' => undef,'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::ObservationUnits'},{'messageType' => 'INFO','message' => 'Observation Units updated'}],'pagination' => {'totalCount' => 1,'totalPages' => 1,'pageSize' => 10,'currentPage' => 0}}});

$mech->get_ok('http://localhost:3010/brapi/v2/observationunits/42867');
$response = decode_json $mech->content;
print STDERR Dumper $response;

$mech->post_ok('http://localhost:3010/brapi/v2/search/observationunits', ['observationUnitDbIds'=>['41300','41301']]);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
# print STDERR Dumper $response;
$mech->get_ok('http://localhost:3010/brapi/v2/search/observationunits/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response,  {'result' => {'data' => [{'observationUnitPUI' => '202','treatments' => [{'modality' => '','factor' => 'No ManagementFactor'}],'observations' => [],'programDbId' => '134','locationDbId' => '23','studyDbId' => '165','trialDbId' => '','locationName' => 'test_location','germplasmDbId' => '41280','observationUnitDbId' => '41300','observationUnitPosition' => {'geoCoordinates' => {'geometry' => {'type' => 'Point','coordinates' => ['-76.506042','42.417373',10]},'type' => 'Feature'},'positionCoordinateXType' => 'GRID_COL','positionCoordinateX' => undef,'observationLevel' => {'levelCode' => '202','levelName' => 'plot','levelOrder' => 2},'entryType' => 'test','observationLevelRelationships' => [{'levelName' => 'replicate','levelCode' => '1','levelOrder' => 0},{'levelName' => 'block','levelCode' => '2','levelOrder' => 1},{'levelName' => 'plot','levelCode' => '202','levelOrder' => 2},{'levelCode' => undef,'levelName' => 'plant','levelOrder' => 4}],'positionCoordinateY' => undef,'positionCoordinateYType' => 'GRID_ROW'},'studyName' => 'CASS_6Genotypes_Sampling_2015','additionalInfo' => {},'trialName' => undef,'observationUnitName' => 'CASS_6Genotypes_202','externalReferences' => [],'germplasmName' => 'TMEB693','programName' => 'test'},{'trialDbId' => '','studyDbId' => '165','treatments' => [{'factor' => 'No ManagementFactor','modality' => ''}],'observations' => [],'programDbId' => '134','observationUnitPUI' => '203','locationDbId' => '23','observationUnitName' => 'CASS_6Genotypes_203','germplasmName' => 'IITA-TMS-IBA980002','programName' => 'test','externalReferences' => [],'observationUnitDbId' => '41301','observationUnitPosition' => {'observationLevelRelationships' => [{'levelName' => 'replicate','levelCode' => '1','levelOrder' => 0},{'levelOrder' => 1,'levelCode' => '2','levelName' => 'block'},{'levelCode' => '203','levelName' => 'plot','levelOrder' => 2},{'levelOrder' => 4,'levelCode' => undef,'levelName' => 'plant'}],'positionCoordinateY' => undef,'positionCoordinateYType' => 'GRID_ROW','observationLevel' => {'levelName' => 'plot','levelCode' => '203','levelOrder' => 2},'entryType' => 'test','positionCoordinateX' => undef,'positionCoordinateXType' => 'GRID_COL','geoCoordinates' => {'geometry' => {'coordinates' => ['-76.506042','42.417373',20],'type' => 'Point'},'type' => 'Feature'}},'locationName' => 'test_location','germplasmDbId' => '41282','trialName' => undef,'studyName' => 'CASS_6Genotypes_Sampling_2015','additionalInfo' => {}}]},'metadata' => {'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Results'},{'message' => 'search result constructed','messageType' => 'INFO'}],'pagination' => {'pageSize' => 10,'totalCount' => 2,'totalPages' => 1,'currentPage' => 0}}});

$mech->get_ok('http://localhost:3010/brapi/v2/observationunits/table');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'headerRow' => ['studyYear','programDbId','programName','programDescription','studyDbId','studyName','studyDescription','studyDesign','plotWidth','plotLength','fieldSize','fieldTrialIsPlannedToBeGenotyped','fieldTrialIsPlannedToCross','plantingDate','harvestDate','locationDbId','locationName','germplasmDbId','germplasmName','germplasmSynonyms','observationLevel','observationUnitDbId','observationUnitName','replicate','blockNumber','plotNumber','rowNumber','colNumber','entryType','plantNumber','plantedSeedlotStockDbId','plantedSeedlotStockUniquename','plantedSeedlotCurrentCount','plantedSeedlotCurrentWeightGram','plantedSeedlotBoxName','plantedSeedlotTransactionCount','plantedSeedlotTransactionWeight','plantedSeedlotTransactionDescription','availableGermplasmSeedlotUniquenames'],'observationVariables' => [{'observationVariableDbId' => '77559','observationVariableName' => 'cass sink leaf|3-phosphoglyceric acid|ug/g|week 16|COMP:0000013'},{'observationVariableName' => 'cass sink leaf|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000011','observationVariableDbId' => '77557'},{'observationVariableDbId' => '77556','observationVariableName' => 'cass sink leaf|ADP|ug/g|week 16|COMP:0000010'},{'observationVariableDbId' => '77548','observationVariableName' => 'cass source leaf|3-phosphoglyceric acid|ug/g|week 16|COMP:0000002'},{'observationVariableName' => 'cass source leaf|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000007','observationVariableDbId' => '77553'},{'observationVariableDbId' => '77549','observationVariableName' => 'cass source leaf|ADP|ug/g|week 16|COMP:0000003'},{'observationVariableDbId' => '77552','observationVariableName' => 'cass storage root|3-phosphoglyceric acid|ug/g|week 16|COMP:0000006'},{'observationVariableDbId' => '77550','observationVariableName' => 'cass storage root|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000004'},{'observationVariableName' => 'cass storage root|ADP|ug/g|week 16|COMP:0000005','observationVariableDbId' => '77551'},{'observationVariableName' => 'cass upper stem|3-phosphoglyceric acid|ug/g|week 16|COMP:0000012','observationVariableDbId' => '77558'},{'observationVariableDbId' => '77554','observationVariableName' => 'cass upper stem|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000008'},{'observationVariableDbId' => '77555','observationVariableName' => 'cass upper stem|ADP|ug/g|week 16|COMP:0000009'},{'observationVariableName' => 'dry matter content percentage|CO_334:0000092','observationVariableDbId' => '70741'},{'observationVariableDbId' => '70666','observationVariableName' => 'fresh root weight|CO_334:0000012'},{'observationVariableName' => 'fresh shoot weight measurement in kg|CO_334:0000016','observationVariableDbId' => '70773'},{'observationVariableDbId' => '70668','observationVariableName' => 'harvest index variable|CO_334:0000015'}],'data' => [['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41283,'IITA-TMS-IBA980581','','plot',41284,'CASS_6Genotypes_103','1','1','103',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','601.518','39.84365','655.92','1259.08','17.38275','192.1495','67.9959','20.3038','102.0875','108.56995','28.83915','379.16',undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41282,'IITA-TMS-IBA980002','','plot',41295,'CASS_6Genotypes_104','1','1','104',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','221.6135','36.12425','316.489','908.9045','29.6934','162.9475','23.09545','14.3795','85.9106','54.2099','13.8628','341.041',undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41279,'IITA-TMS-IBA30572','','plot',41296,'CASS_6Genotypes_105','1','1','105',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','662.087','46.1458','559.441','1974.265','38.1064','484.765','33.1455','16.7238','98.71395','97.8179','35.4435','439.9695',undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41281,'IITA-TMS-IBA011412','','plot',41297,'CASS_6Genotypes_106','1','1','106',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','612.37','23.788','604.5625','646.902','26.60415','192.46','39.6698','16.78125','107.74','78.72305','28.3805','469.818',undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41280,'TMEB693','','plot',41298,'CASS_6Genotypes_107','1','1','107',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','198.089','47.64845','485.944','779.191','21.12875','147.0405','31.554','10.59626','46.41935','101.7506','30.86975','423.355',undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',40326,'BLANK','','plot',41299,'CASS_6Genotypes_201','1','2','201',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'',undef,undef,undef,undef,undef,undef,undef,undef,undef,undef,undef,undef,undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41280,'TMEB693','','plot',41300,'CASS_6Genotypes_202','1','2','202',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','250.228','39.2627','478.0445','1295.29','21.56485','169.757','26.2744','5.31292','39.4774','61.51325','36.2316','241.418',undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41282,'IITA-TMS-IBA980002','','plot',41301,'CASS_6Genotypes_203','1','2','203',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','245.679','29.4029','299.096','1013.111','17.04795','202.893','40.306','7.442495','75.2132','57.47695','20.43645','303.3225',undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41283,'IITA-TMS-IBA980581','','plot',41302,'CASS_6Genotypes_204','1','2','204',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','235.825','31.0018','491.9535','1302.695','22.82925','281.091','74.1941','15.9235','83.2802','154.109','31.2364','849.9465',undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41281,'IITA-TMS-IBA011412','','plot',41285,'CASS_6Genotypes_205','1','2','205',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','415.062','61.2228','730.363','1757.615','23.07085','276.8625','49.3781','21.6087','86.7917','73.25295','17.81095','363.986',undef,undef,undef,undef,undef]]},'metadata' => {'datafiles' => [],'pagination' => {'totalPages' => 196,'pageSize' => 10,'totalCount' => 1955,'currentPage' => 0},'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::ObservationTables'},{'message' => 'Observation Units table result constructed','messageType' => 'INFO'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/observations?pageSize=2');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'germplasmName' => 'IITA-TMS-IBA980581','value' => '601.518','germplasmDbId' => '41283','observationVariableName' => 'cass sink leaf|3-phosphoglyceric acid|ug/g|week 16|COMP:0000013','season' => [{'year' => '2017','seasonDbId' => '2017','season' => '2017'}],'observationUnitDbId' => '41284','observationTimeStamp' => undef,'uploadedBy' => undef,'externalReferences' => undef,'collector' => 'johndoe','studyDbId' => '165','additionalInfo' => undef,'observationVariableDbId' => '77559','observationDbId' => '740336','observationUnitName' => 'CASS_6Genotypes_103'},{'germplasmName' => 'IITA-TMS-IBA980581','observationVariableName' => 'cass sink leaf|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000011','germplasmDbId' => '41283','value' => '39.84365','season' => [{'year' => '2017','seasonDbId' => '2017','season' => '2017'}],'observationUnitDbId' => '41284','observationTimeStamp' => undef,'uploadedBy' => undef,'externalReferences' => undef,'collector' => 'johndoe','studyDbId' => '165','additionalInfo' => undef,'observationVariableDbId' => '77557','observationDbId' => '740337','observationUnitName' => 'CASS_6Genotypes_103'}]},'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=2'},{'message' => 'Loading CXGN::BrAPI::v2::Observations','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Observations result constructed'}],'pagination' => {'currentPage' => 0,'totalPages' => 6,'pageSize' => 2,'totalCount' => 12},'datafiles' => []}});

$mech->get_ok('http://localhost:3010/brapi/v2/observations/740338');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response,  {'metadata' => {'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Observations'},{'messageType' => 'INFO','message' => 'Observations result constructed'}],'pagination' => {'totalCount' => 1,'totalPages' => 1,'currentPage' => 0,'pageSize' => 10}},'result' => {'data' => [{'externalReferences' => undef,'value' => '655.92','germplasmDbId' => '41283','season' => [{'seasonDbId' => 2017,'season' => 2017,'year' => '2017'}],'studyDbId' => '165','observationVariableName' => 'cass sink leaf|ADP|ug/g|week 16|COMP:0000010','observationVariableDbId' => '77556','observationUnitDbId' => '41284','germplasmName' => 'IITA-TMS-IBA980581','observationTimeStamp' => undef,'uploadedBy' => undef,'collector' => 'johndoe','observationUnitName' => 'CASS_6Genotypes_103','observationDbId' => '740338','additionalInfo' => undef}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/observations/table?pageSize=2');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'observationVariables' => [{'observationVariableDbId' => '77559','observationVariableName' => 'cass sink leaf|3-phosphoglyceric acid|ug/g|week 16|COMP:0000013'},{'observationVariableName' => 'cass sink leaf|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000011','observationVariableDbId' => '77557'},{'observationVariableDbId' => '77556','observationVariableName' => 'cass sink leaf|ADP|ug/g|week 16|COMP:0000010'},{'observationVariableName' => 'cass source leaf|3-phosphoglyceric acid|ug/g|week 16|COMP:0000002','observationVariableDbId' => '77548'},{'observationVariableName' => 'cass source leaf|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000007','observationVariableDbId' => '77553'},{'observationVariableDbId' => '77549','observationVariableName' => 'cass source leaf|ADP|ug/g|week 16|COMP:0000003'},{'observationVariableName' => 'cass storage root|3-phosphoglyceric acid|ug/g|week 16|COMP:0000006','observationVariableDbId' => '77552'},{'observationVariableDbId' => '77550','observationVariableName' => 'cass storage root|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000004'},{'observationVariableDbId' => '77551','observationVariableName' => 'cass storage root|ADP|ug/g|week 16|COMP:0000005'},{'observationVariableDbId' => '77558','observationVariableName' => 'cass upper stem|3-phosphoglyceric acid|ug/g|week 16|COMP:0000012'},{'observationVariableDbId' => '77554','observationVariableName' => 'cass upper stem|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000008'},{'observationVariableName' => 'cass upper stem|ADP|ug/g|week 16|COMP:0000009','observationVariableDbId' => '77555'},{'observationVariableName' => 'dry matter content percentage|CO_334:0000092','observationVariableDbId' => '70741'},{'observationVariableName' => 'fresh root weight|CO_334:0000012','observationVariableDbId' => '70666'},{'observationVariableDbId' => '70773','observationVariableName' => 'fresh shoot weight measurement in kg|CO_334:0000016'},{'observationVariableDbId' => '70668','observationVariableName' => 'harvest index variable|CO_334:0000015'}],'data' => [['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41283,'IITA-TMS-IBA980581','','plot',41284,'CASS_6Genotypes_103','1','1','103',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','601.518','39.84365','655.92','1259.08','17.38275','192.1495','67.9959','20.3038','102.0875','108.56995','28.83915','379.16',undef,undef,undef,undef,undef],['2017',134,'test','test',165,'CASS_6Genotypes_Sampling_2015','Copy of trial with postcomposed phenotypes from cassbase.','RCBD',undef,undef,undef,undef,undef,undef,undef,'23','test_location',41282,'IITA-TMS-IBA980002','','plot',41295,'CASS_6Genotypes_104','1','1','104',undef,undef,'test',undef,undef,undef,undef,undef,undef,undef,undef,undef,'','221.6135','36.12425','316.489','908.9045','29.6934','162.9475','23.09545','14.3795','85.9106','54.2099','13.8628','341.041',undef,undef,undef,undef,undef]],'headerRow' => ['studyYear','programDbId','programName','programDescription','studyDbId','studyName','studyDescription','studyDesign','plotWidth','plotLength','fieldSize','fieldTrialIsPlannedToBeGenotyped','fieldTrialIsPlannedToCross','plantingDate','harvestDate','locationDbId','locationName','germplasmDbId','germplasmName','germplasmSynonyms','observationLevel','observationUnitDbId','observationUnitName','replicate','blockNumber','plotNumber','rowNumber','colNumber','entryType','plantNumber','plantedSeedlotStockDbId','plantedSeedlotStockUniquename','plantedSeedlotCurrentCount','plantedSeedlotCurrentWeightGram','plantedSeedlotBoxName','plantedSeedlotTransactionCount','plantedSeedlotTransactionWeight','plantedSeedlotTransactionDescription','availableGermplasmSeedlotUniquenames']},'metadata' => {'pagination' => {'currentPage' => 0,'totalPages' => 978,'totalCount' => 1955,'pageSize' => 2},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=2','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::ObservationTables','messageType' => 'INFO'},{'message' => 'Observations table result constructed','messageType' => 'INFO'}],'datafiles' => []}});

$mech->post_ok('http://localhost:3010/brapi/v2/search/observations', ['pageSize'=>'2', 'observationDbIds' => ['740337']]);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
print STDERR Dumper $response;
$mech->get_ok('http://localhost:3010/brapi/v2/search/observations/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Results'},{'message' => 'search result constructed','messageType' => 'INFO'}],'pagination' => {'totalCount' => 1,'currentPage' => 0,'pageSize' => 10,'totalPages' => 1},'datafiles' => []},'result' => {'data' => [{'observationVariableName' => 'cass sink leaf|ADP alpha-D-glucoside|ug/g|week 16|COMP:0000011','germplasmDbId' => '41283','studyDbId' => '165','observationTimeStamp' => undef,'collector' => 'johndoe','value' => '39.84365','observationVariableDbId' => '77557','observationDbId' => '740337','observationUnitName' => 'CASS_6Genotypes_103','externalReferences' => undef,'observationUnitDbId' => '41284','season' => [{'seasonDbId' => '2017','season' => '2017','year' => '2017'}],'uploadedBy' => undef,'germplasmName' => 'IITA-TMS-IBA980581','additionalInfo' => undef}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/variables?pageSize=2');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response,  {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=2'},{'message' => 'Loading CXGN::BrAPI::v2::ObservationVariables','messageType' => 'INFO'},{'message' => 'Observationvariable search result constructed','messageType' => 'INFO'}],'pagination' => {'totalCount' => 242,'pageSize' => 2,'totalPages' => 121,'currentPage' => 0},'datafiles' => []},'result' => {'data' => [{'synonyms' => ['abscon','AbsCt_Meas_ugg'],'observationVariableDbId' => '70692','additionalInfo' => {},'language' => 'eng','defaultValue' => '','scientist' => undef,'documentationURL' => '','institution' => undef,'observationVariableName' => 'abscisic acid content of leaf ug/g|CO_334:0000047','contextOfUse' => undef,'trait' => {'synonyms' => ['abscon','AbsCt_Meas_ugg'],'entity' => undef,'ontologyReference' => {'ontologyDbId' => 186,'ontologyName' => 'CO_334','documentationLinks' => undef,'version' => undef},'traitDbId' => '70692','externalReferences' => 'CO_334:0000047','status' => 'Active','additionalInfo' => {},'traitName' => 'abscisic acid content of leaf ug/g','traitDescription' => 'Abscisic acid content of leaf sample.','attribute' => 'abscisic acid content of leaf ug/g','traitClass' => undef,'alternativeAbbreviations' => undef,'mainAbbreviation' => undef},'status' => 'Active','externalReferences' => 'CO_334:0000047','ontologyReference' => {'documentationLinks' => undef,'ontologyDbId' => '186','ontologyName' => 'CO_334','version' => undef},'method' => {},'growthStage' => undef,'commonCropName' => 'Cassava','scale' => {'validValues' => {'categories' => [],'max' => undef,'min' => undef},'scaleDbId' => undef,'scaleName' => undef,'datatype' => '','decimalPlaces' => undef,'ontologyReference' => {},'additionalInfo' => {},'externalReferences' => ''},'submissionTimestamp' => undef},{'trait' => {'traitClass' => undef,'alternativeAbbreviations' => undef,'mainAbbreviation' => undef,'synonyms' => ['amylp','AmylPCt_Meas_pct'],'entity' => undef,'traitDbId' => '70761','additionalInfo' => {},'traitDescription' => 'Estimation of amylopectin content of cassava roots in percentage(%).','attribute' => 'amylopectin content ug/g in percentage','ontologyReference' => {'documentationLinks' => undef,'ontologyName' => 'CO_334','ontologyDbId' => 186,'version' => undef},'traitName' => 'amylopectin content ug/g in percentage','status' => 'Active','externalReferences' => 'CO_334:0000121'},'contextOfUse' => undef,'ontologyReference' => {'ontologyDbId' => '186','ontologyName' => 'CO_334','documentationLinks' => undef,'version' => undef},'externalReferences' => 'CO_334:0000121','status' => 'Active','growthStage' => undef,'method' => {},'scale' => {'externalReferences' => '','additionalInfo' => {},'ontologyReference' => {},'decimalPlaces' => undef,'scaleName' => undef,'scaleDbId' => undef,'validValues' => {'max' => undef,'min' => undef,'categories' => []},'datatype' => ''},'submissionTimestamp' => undef,'commonCropName' => 'Cassava','synonyms' => ['amylp','AmylPCt_Meas_pct'],'observationVariableDbId' => '70761','scientist' => undef,'defaultValue' => '','language' => 'eng','additionalInfo' => {},'institution' => undef,'documentationURL' => '','observationVariableName' => 'amylopectin content ug/g in percentage|CO_334:0000121'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/variables/70752');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'status' => 'Active','method' => {},'scale' => {'scaleName' => undef,'datatype' => '','externalReferences' => '','scaleDbId' => undef,'ontologyReference' => {},'decimalPlaces' => undef,'validValues' => {'max' => undef,'min' => undef,'categories' => []}},'synonyms' => ['AmylR_Comp_r','amylrt'],'additionalInfo' => undef,'ontologyReference' => {'documentationLinks' => undef,'version' => undef,'ontologyName' => 'CO_334','ontologyDbId' => '186'},'growthStage' => undef,'trait' => {'entity' => undef,'traitClass' => undef,'externalReferences' => 'CO_334:0000124','traitDescription' => 'The amylose content of a cassava root sample divided by the amylopectin content of the same sample.','attribute' => 'amylose amylopectin root content ratio','traitDbId' => '70752','alternativeAbbreviations' => undef,'status' => 'Active','ontologyReference' => {'ontologyDbId' => 186,'ontologyName' => 'CO_334','version' => undef,'documentationLinks' => undef},'synonyms' => ['AmylR_Comp_r','amylrt'],'mainAbbreviation' => undef,'traitName' => 'amylose amylopectin root content ratio'},'observationVariableName' => 'amylose amylopectin root content ratio|CO_334:0000124','contextOfUse' => undef,'commonCropName' => 'Cassava','defaultValue' => '','submissionTimestamp' => undef,'documentationURL' => '','externalReferences' => 'CO_334:0000124','scientist' => undef,'observationVariableDbId' => '70752','institution' => undef,'language' => 'eng'},'metadata' => {'pagination' => {'currentPage' => 0,'pageSize' => 10,'totalCount' => 1,'totalPages' => 1},'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::ObservationVariables'},{'messageType' => 'INFO','message' => 'Observationvariable search result constructed'}],'datafiles' => []}});

$mech->post_ok('http://localhost:3010/brapi/v2/search/variables', ['pageSize'=>'1', 'observationVariableDbIds' => ['70761']]);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
print STDERR Dumper $response;
$mech->get_ok('http://localhost:3010/brapi/v2/search/variables/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'institution' => undef,'language' => 'eng','observationVariableDbId' => '70761','documentationURL' => '','submissionTimestamp' => undef,'scientist' => undef,'externalReferences' => 'CO_334:0000121','observationVariableName' => 'amylopectin content ug/g in percentage|CO_334:0000121','trait' => {'attribute' => 'amylopectin content ug/g in percentage','traitDescription' => 'Estimation of amylopectin content of cassava roots in percentage(%).','traitDbId' => '70761','alternativeAbbreviations' => undef,'entity' => undef,'traitClass' => undef,'externalReferences' => 'CO_334:0000121','traitName' => 'amylopectin content ug/g in percentage','status' => 'Active','ontologyReference' => {'ontologyDbId' => 186,'version' => undef,'ontologyName' => 'CO_334','documentationLinks' => undef},'mainAbbreviation' => undef,'additionalInfo' => {},'synonyms' => ['amylp','AmylPCt_Meas_pct']},'growthStage' => undef,'commonCropName' => undef,'defaultValue' => '','contextOfUse' => undef,'synonyms' => ['amylp','AmylPCt_Meas_pct'],'additionalInfo' => {},'ontologyReference' => {'documentationLinks' => undef,'version' => undef,'ontologyName' => 'CO_334','ontologyDbId' => '186'},'method' => {},'status' => 'Active','scale' => {'externalReferences' => '','scaleDbId' => undef,'ontologyReference' => {},'datatype' => '','additionalInfo' => {},'scaleName' => undef,'validValues' => {'categories' => [],'max' => undef,'min' => undef},'decimalPlaces' => undef}}]},'metadata' => {'datafiles' => [],'pagination' => {'totalCount' => 1,'pageSize' => 10,'currentPage' => 0,'totalPages' => 1},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Results'},{'message' => 'search result constructed','messageType' => 'INFO'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/traits?pageSize=2');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'ontologyReference' => {'version' => undef,'ontologyName' => 'CHEBI','ontologyDbId' => 88,'documentationLinks' => undef},'traitName' => '1-pyrroline-2-carboxylic acid','traitDescription' => 'The product resulting from formal oxidation of DL-proline by loss of hydrogen from the nitrogen and from the carbon alpha to the carboxylic acid, with the formation of a C=N bond.','alternativeAbbreviations' => undef,'entity' => undef,'traitClass' => undef,'additionalInfo' => {},'status' => 'Active','mainAbbreviation' => undef,'attribute' => '1-pyrroline-2-carboxylic acid','externalReferences' => [],'synonyms' => ['1-Pyrroline-2-carboxylate','1-Pyrroline-2-carboxylic acid','delta1-Pyrroline 2-carboxylate','3,4-dihydro-2H-pyrrole-5-carboxylic acid','RHTAIKJZSXNELN-UHFFFAOYSA-N','InChI=1S/C5H7NO2/c7-5(8)4-2-1-3-6-4/h1-3H2,(H,7,8)','OC(=O)C1=NCCC1','C5H7NO2'],'traitDbId' => '77298'},{'traitClass' => undef,'entity' => undef,'traitName' => '2-oxoglutarate(1-)','traitDescription' => 'A dicarboxylic acid monoanion resulting from selective deprotonation of the 1-carboxy group of 2-oxoglutaric acid.','alternativeAbbreviations' => undef,'ontologyReference' => {'ontologyName' => 'CHEBI','ontologyDbId' => 88,'documentationLinks' => undef,'version' => undef},'externalReferences' => [],'synonyms' => ['2-ketoglutarate','4-carboxy-2-oxobutanoate','C5H5O5','OC(=O)CCC(=O)C([O-])=O','InChI=1S/C5H6O5/c6-3(5(9)10)1-2-4(7)8/h1-2H2,(H,7,8)(H,9,10)/p-1','KPGXRSRHYNQIFN-UHFFFAOYSA-M','2-ketoglutarate','4-carboxy-2-oxobutanoate','C5H5O5','OC(=O)CCC(=O)C([O-])=O','InChI=1S/C5H6O5/c6-3(5(9)10)1-2-4(7)8/h1-2H2,(H,7,8)(H,9,10)/p-1','KPGXRSRHYNQIFN-UHFFFAOYSA-M'],'traitDbId' => '77201','mainAbbreviation' => undef,'attribute' => '2-oxoglutarate(1-)','additionalInfo' => {},'status' => 'Active'}]},'metadata' => {'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=2','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::Traits','messageType' => 'INFO'},{'message' => 'Traits list result constructed','messageType' => 'INFO'}],'pagination' => {'totalCount' => 696,'currentPage' => 0,'totalPages' => 348,'pageSize' => 2},'datafiles' => []}});
$mech->get_ok('http://localhost:3010/brapi/v2/traits/77216');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response,  {'result' => {'ontologyReference' => {'version' => undef,'ontologyName' => 'CHEBI','documentationLinks' => undef,'ontologyDbId' => 88},'alternativeAbbreviations' => undef,'traitDescription' => 'A monophosphoglyceric acid having the phospho group at the 3-position. It is an intermediate in metabolic pathways like glycolysis and calvin cycle.','traitName' => '3-phosphoglyceric acid','entity' => undef,'traitClass' => undef,'status' => 'Active','attribute' => '3-phosphoglyceric acid','mainAbbreviation' => undef,'traitDbId' => '77216','externalReferences' => [],'synonyms' => undef},'metadata' => {'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::Traits','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Trait detail result constructed'}],'pagination' => {'totalPages' => 1,'currentPage' => 0,'totalCount' => 1,'pageSize' => 10}}});


# $mech->get_ok('http://localhost:3010/brapi/v2/ontologies?pageSize=10');
# $response = decode_json $mech->content;
# print STDERR Dumper $response;

$mech->get_ok('http://localhost:3010/brapi/v2/germplasm?pageSize=3');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'subtaxa' => undef,'germplasmPUI' => '','species' => undef,'subtaxaAuthority' => undef,'biologicalStatusOfAccessionCode' => 0,'donors' => [{'germplasmPUI' => undef,'donorAccessionNumber' => undef,'donorInstituteCode' => undef}],'commonCropName' => undef,'speciesAuthority' => undef,'additionalInfo' => undef,'germplasmName' => 'BLANK','externalReferences' => [],'instituteCode' => '','taxonIds' => [],'storageTypes' => [],'defaultDisplayName' => 'BLANK','acquisitionDate' => '','biologicalStatusOfAccessionDescription' => undef,'documentationURL' => '','countryOfOriginCode' => '','seedSourceDescription' => '','pedigree' => 'NA/NA','synonyms' => [],'germplasmOrigin' => [],'collection' => undef,'instituteName' => '','accessionNumber' => '','germplasmPreprocessing' => undef,'seedSource' => '','genus' => undef,'germplasmDbId' => '40326','breedingMethodDbId' => undef},{'germplasmPUI' => '','subtaxa' => undef,'species' => 'Manihot esculenta','germplasmName' => 'IITA-TMS-IBA30572','additionalInfo' => undef,'externalReferences' => [],'biologicalStatusOfAccessionCode' => 0,'donors' => [{'germplasmPUI' => undef,'donorInstituteCode' => undef,'donorAccessionNumber' => undef}],'subtaxaAuthority' => undef,'speciesAuthority' => undef,'commonCropName' => undef,'countryOfOriginCode' => '','storageTypes' => [],'defaultDisplayName' => 'IITA-TMS-IBA30572','instituteCode' => '','taxonIds' => [],'documentationURL' => '','acquisitionDate' => '','biologicalStatusOfAccessionDescription' => undef,'seedSource' => '','genus' => 'Manihot','accessionNumber' => '','germplasmPreprocessing' => undef,'breedingMethodDbId' => undef,'germplasmDbId' => '41279','seedSourceDescription' => '','pedigree' => 'NA/NA','germplasmOrigin' => [],'synonyms' => [],'collection' => undef,'instituteName' => ''},{'species' => 'Manihot esculenta','germplasmPUI' => '','subtaxa' => undef,'externalReferences' => [],'germplasmName' => 'IITA-TMS-IBA011412','additionalInfo' => undef,'speciesAuthority' => undef,'commonCropName' => undef,'biologicalStatusOfAccessionCode' => 0,'donors' => [{'donorAccessionNumber' => undef,'donorInstituteCode' => undef,'germplasmPUI' => undef}],'subtaxaAuthority' => undef,'countryOfOriginCode' => '','documentationURL' => '','acquisitionDate' => '','biologicalStatusOfAccessionDescription' => undef,'defaultDisplayName' => 'IITA-TMS-IBA011412','storageTypes' => [],'instituteCode' => '','taxonIds' => [],'breedingMethodDbId' => undef,'germplasmDbId' => '41281','seedSource' => '','genus' => 'Manihot','accessionNumber' => '','germplasmPreprocessing' => undef,'synonyms' => [],'germplasmOrigin' => [],'collection' => undef,'instituteName' => '','seedSourceDescription' => '','pedigree' => 'NA/NA'}]},'metadata' => {'pagination' => {'totalPages' => 160,'totalCount' => 479,'pageSize' => 3,'currentPage' => 0},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=3','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::Germplasm','messageType' => 'INFO'},{'message' => 'Germplasm result constructed','messageType' => 'INFO'}],'datafiles' => []}});

$mech->get_ok('http://localhost:3010/brapi/v2/germplasm/41281');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'biologicalStatusOfAccessionDescription' => undef,'acquisitionDate' => '','documentationURL' => '','instituteCode' => '','taxonIds' => [],'storageTypes' => [],'defaultDisplayName' => 'IITA-TMS-IBA011412','countryOfOriginCode' => '','instituteName' => '','collection' => undef,'germplasmOrigin' => [],'synonyms' => [],'pedigree' => 'NA/NA','seedSourceDescription' => '','germplasmDbId' => '41281','breedingMethodDbId' => undef,'germplasmPreprocessing' => undef,'accessionNumber' => '','genus' => 'Manihot','seedSource' => '','species' => 'Manihot esculenta','subtaxa' => undef,'germplasmPUI' => '','commonCropName' => undef,'speciesAuthority' => undef,'subtaxaAuthority' => undef,'donors' => [{'germplasmPUI' => undef,'donorInstituteCode' => undef,'donorAccessionNumber' => undef}],'biologicalStatusOfAccessionCode' => 0,'externalReferences' => [],'additionalInfo' => undef,'germplasmName' => 'IITA-TMS-IBA011412'},'metadata' => {'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::Germplasm','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Germplasm detail result constructed'}],'pagination' => {'totalCount' => 1,'pageSize' => 10,'currentPage' => 0,'totalPages' => 1}}});

$mech->get_ok('http://localhost:3010/brapi/v2/germplasm/38843/progeny');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Germplasm'},{'message' => 'Germplasm progeny result constructed','messageType' => 'INFO'}],'pagination' => {'totalCount' => 15,'totalPages' => 2,'pageSize' => 10,'currentPage' => 0},'datafiles' => []},'result' => {'germplasmName' => 'test_accession4','progeny' => [{'parentType' => 'FEMALE','germplasmDbId' => '38846','germplasmName' => 'new_test_crossP001'},{'germplasmName' => 'new_test_crossP002','germplasmDbId' => '38847','parentType' => 'FEMALE'},{'parentType' => 'FEMALE','germplasmName' => 'new_test_crossP003','germplasmDbId' => '38848'},{'parentType' => 'FEMALE','germplasmName' => 'new_test_crossP004','germplasmDbId' => '38849'},{'parentType' => 'FEMALE','germplasmName' => 'new_test_crossP005','germplasmDbId' => '38850'},{'germplasmDbId' => '38851','germplasmName' => 'new_test_crossP006','parentType' => 'FEMALE'},{'germplasmName' => 'new_test_crossP007','germplasmDbId' => '38852','parentType' => 'FEMALE'},{'parentType' => 'FEMALE','germplasmName' => 'new_test_crossP008','germplasmDbId' => '38853'},{'parentType' => 'FEMALE','germplasmName' => 'new_test_crossP009','germplasmDbId' => '38854'},{'parentType' => 'FEMALE','germplasmName' => 'new_test_crossP010','germplasmDbId' => '38855'}],'germplasmDbId' => '38843'}});

$mech->get_ok('http://localhost:3010/brapi/v2/germplasm/41279/mcpd');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'totalCount' => 1,'totalPages' => 1,'currentPage' => 0,'pageSize' => 10},'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::Germplasm','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Germplasm detail result constructed'}]},'result' => {'storageTypeCodes' => [],'germplasmPUI' => '','collectingInfo' => {},'breedingInstitutes' => {'instituteCode' => '','instituteName' => ''},'safetyDuplicateInstitutes' => undef,'genus' => 'Manihot','species' => 'Manihot esculenta','subtaxonAuthority' => undef,'commonCropName' => undef,'remarks' => undef,'alternateIDs' => [41279],'donorInfo' => [],'speciesAuthority' => undef,'biologicalStatusOfAccessionCode' => 0,'instituteCode' => '','accessionNames' => ['IITA-TMS-IBA30572','IITA-TMS-IBA30572'],'mlsStatus' => undef,'accessionNumber' => '','acquisitionDate' => '','germplasmDbId' => '41279','subtaxon' => undef,'ancestralData' => 'NA/NA','countryOfOrigin' => ''}});

$mech->get_ok('http://localhost:3010/brapi/v2/germplasm/38876/pedigree');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'currentPage' => 0,'pageSize' => 1,'totalPages' => 1,'totalCount' => 1},'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Germplasm'},{'messageType' => 'INFO','message' => 'Germplasm pedigree result constructed'}]},'result' => {'germplasmName' => 'test5P004','germplasmDbId' => '38876','crossingProjectDbId' => undef,'familyCode' => '','pedigree' => 'test_accession4/test_accession5','parents' => [{'parentType' => 'FEMALE','germplasmName' => 'test_accession4','germplasmDbId' => '38843'},{'germplasmDbId' => '38844','germplasmName' => 'test_accession5','parentType' => 'MALE'}],'crossingYear' => '','siblings' => [{'germplasmName' => 'new_test_crossP001','germplasmDbId' => '38846'},{'germplasmDbId' => '38847','germplasmName' => 'new_test_crossP002'},{'germplasmDbId' => '38848','germplasmName' => 'new_test_crossP003'},{'germplasmName' => 'new_test_crossP004','germplasmDbId' => '38849'},{'germplasmDbId' => '38850','germplasmName' => 'new_test_crossP005'},{'germplasmName' => 'new_test_crossP006','germplasmDbId' => '38851'},{'germplasmDbId' => '38852','germplasmName' => 'new_test_crossP007'},{'germplasmName' => 'new_test_crossP008','germplasmDbId' => '38853'},{'germplasmDbId' => '38854','germplasmName' => 'new_test_crossP009'},{'germplasmName' => 'new_test_crossP010','germplasmDbId' => '38855'},{'germplasmDbId' => '38873','germplasmName' => 'test5P001'},{'germplasmDbId' => '38874','germplasmName' => 'test5P002'},{'germplasmDbId' => '38875','germplasmName' => 'test5P003'},{'germplasmName' => 'test5P005','germplasmDbId' => '38877'}]}});

$mech->post_ok('http://localhost:3010/brapi/v2/search/germplasm', ['germplasmDbIds' => ['40326']]);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
print STDERR Dumper $response;
$mech->get_ok('http://localhost:3010/brapi/v2/search/germplasm/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'totalPages' => 1,'currentPage' => 0,'totalCount' => 1,'pageSize' => 10},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Results'},{'messageType' => 'INFO','message' => 'search result constructed'}],'datafiles' => []},'result' => {'data' => [{'germplasmName' => 'BLANK','externalReferences' => [],'storageTypes' => [],'genus' => undef,'acquisitionDate' => '','subtaxa' => undef,'subtaxaAuthority' => undef,'accessionNumber' => '','donors' => [{'donorAccessionNumber' => undef,'germplasmPUI' => undef,'donorInstituteCode' => undef}],'biologicalStatusOfAccessionDescription' => undef,'seedSource' => '','pedigree' => 'NA/NA','germplasmOrigin' => [],'countryOfOriginCode' => '','collection' => undef,'documentationURL' => '','breedingMethodDbId' => undef,'seedSourceDescription' => '','biologicalStatusOfAccessionCode' => 0,'instituteName' => '','germplasmPUI' => '','commonCropName' => undef,'germplasmDbId' => '40326','taxonIds' => [],'instituteCode' => '','additionalInfo' => undef,'speciesAuthority' => undef,'species' => undef,'germplasmPreprocessing' => undef,'defaultDisplayName' => 'BLANK','synonyms' => []}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/crossingprojects/');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::Crossing','messageType' => 'INFO'},{'message' => 'Crossing projects result constructed','messageType' => 'INFO'}],'datafiles' => [],'pagination' => {'totalCount' => 6,'currentPage' => 0,'totalPages' => 1,'pageSize' => 10}},'result' => {'data' => [{'commonCropName' => undef,'externalReferences' => [],'additionalInfo' => {},'crossingProjectDescription' => 'CASS_6Genotypes_Sampling_2015','programDbId' => '134','programName' => 'test','crossingProjectDbId' => '165','crossingProjectName' => 'CASS_6Genotypes_Sampling_2015'},{'commonCropName' => undef,'externalReferences' => [],'crossingProjectDescription' => 'Kasese solgs trial','additionalInfo' => {},'programName' => 'test','programDbId' => '134','crossingProjectDbId' => '139','crossingProjectName' => 'Kasese solgs trial'},{'crossingProjectDbId' => '135','crossingProjectName' => 'new_test_cross','additionalInfo' => {},'crossingProjectDescription' => 'new_test_cross','externalReferences' => [],'programName' => 'test','programDbId' => '134','commonCropName' => undef},{'programName' => 'test','programDbId' => '134','externalReferences' => [],'additionalInfo' => {},'crossingProjectDescription' => 'test_t','commonCropName' => undef,'crossingProjectName' => 'test_t','crossingProjectDbId' => '144'},{'crossingProjectName' => 'test_trial','crossingProjectDbId' => '137','commonCropName' => undef,'programDbId' => '134','programName' => 'test','additionalInfo' => {},'crossingProjectDescription' => 'test_trial','externalReferences' => []},{'crossingProjectName' => 'trial2 NaCRRI','crossingProjectDbId' => '141','programDbId' => '134','programName' => 'test','externalReferences' => [],'additionalInfo' => {},'crossingProjectDescription' => 'trial2 NaCRRI','commonCropName' => undef}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/crossingprojects/139');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Crossing'},{'message' => 'Crossing projects result constructed','messageType' => 'INFO'}],'pagination' => {'currentPage' => 0,'totalCount' => 1,'pageSize' => 10,'totalPages' => 1},'datafiles' => []},'result' => {'programName' => 'test','commonCropName' => undef,'crossingProjectName' => 'Kasese solgs trial','crossingProjectDescription' => 'Kasese solgs trial','programDbId' => '134','crossingProjectDbId' => '139','additionalInfo' => {},'externalReferences' => []}});

$mech->get_ok('http://localhost:3010/brapi/v2/seedlots');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'additionalInfo' 
=> {},'lastUpdated' => undef,'programDbId' => '134','amount' => '1','germplasmDbId' => '38846','externalReferences' => [],'seedLotName' => 'new_test_crossP001_001','seedLotDbId' => '41305','sourceCollection' => undef,'createdDate' => undef,'storageLocation' => 'NA','units' => 'seeds','seedLotDescription' => '','crossDbId' => undef,'locationDbId' => '25'},{'seedLotDescription' => '','crossDbId' => undef,'locationDbId' => '25','externalReferences' => [],'sourceCollection' => undef,'seedLotDbId' => '41306','seedLotName' => 'new_test_crossP002_001','storageLocation' => 'NA','createdDate' => undef,'units' => 'seeds','programDbId' => '134','lastUpdated' => undef,'amount' => '1','germplasmDbId' => '38847','additionalInfo' => {}},{'programDbId' => '134','lastUpdated' => undef,'germplasmDbId' => '38848','amount' => '1','additionalInfo' => {},'seedLotDescription' => '','locationDbId' => '25','crossDbId' => undef,'seedLotDbId' => '41307','seedLotName' => 'new_test_crossP003_001','sourceCollection' => undef,'externalReferences' => [],'units' => 'seeds','storageLocation' => 'NA','createdDate' => undef},{'units' => 'seeds','createdDate' => undef,'storageLocation' => 'NA','sourceCollection' => undef,'seedLotDbId' => '41308','seedLotName' => 'new_test_crossP004_001','externalReferences' => [],'locationDbId' => '25','crossDbId' => undef,'seedLotDescription' => '','additionalInfo' => {},'germplasmDbId' => '38849','amount' => '1','lastUpdated' => undef,'programDbId' => '134'},{'sourceCollection' => undef,'seedLotName' => 'new_test_crossP005_001','seedLotDbId' => '41309','externalReferences' => [],'units' => 'seeds','storageLocation' => 'NA','createdDate' => undef,'seedLotDescription' => '','locationDbId' => '25','crossDbId' => undef,'additionalInfo' => {},'programDbId' => '134','lastUpdated' => undef,'germplasmDbId' => '38850','amount' => '1'},{'seedLotDescription' => '','crossDbId' => undef,'locationDbId' => '25','externalReferences' => [],'seedLotName' => 'new_test_crossP006_001','sourceCollection' => undef,'seedLotDbId' => '41310','storageLocation' => 'NA','createdDate' => undef,'units' => 'seeds','programDbId' => '134','lastUpdated' => undef,'amount' => '1','germplasmDbId' => '38851','additionalInfo' => {}},{'locationDbId' => '25','crossDbId' => undef,'seedLotDescription' => '','units' => 'seeds','createdDate' => undef,'storageLocation' => 'NA','seedLotName' => 'new_test_crossP007_001','seedLotDbId' => '41311','sourceCollection' => undef,'externalReferences' => [],'germplasmDbId' => '38852','amount' => '1','lastUpdated' => undef,'programDbId' => '134','additionalInfo' => {}},{'createdDate' => undef,'storageLocation' => 'NA','units' => 'seeds','externalReferences' => [],'sourceCollection' => undef,'seedLotName' => 'new_test_crossP008_001','seedLotDbId' => '41312','crossDbId' => undef,'locationDbId' => '25','seedLotDescription' => '','additionalInfo' => {},'amount' => '1','germplasmDbId' => '38853','lastUpdated' => undef,'programDbId' => '134'},{'additionalInfo' => {},'amount' => '1','germplasmDbId' => '38843','lastUpdated' => undef,'programDbId' => '134','createdDate' => undef,'storageLocation' => 'NA','units' => 'seeds','externalReferences' => [],'seedLotName' => 'test_accession4_001','sourceCollection' => undef,'seedLotDbId' => '41303','crossDbId' => undef,'locationDbId' => '25','seedLotDescription' => ''},{'seedLotDescription' => '','locationDbId' => '25','crossDbId' => undef,'seedLotName' => 'test_accession5_001','seedLotDbId' => '41304','sourceCollection' => undef,'externalReferences' => [],'units' => 'seeds','storageLocation' => 'NA','createdDate' => undef,'programDbId' => '134','lastUpdated' => undef,'germplasmDbId' => '38844','amount' => '1','additionalInfo' => {}}]},'metadata' => {'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::SeedLots','messageType' => 'INFO'},{'message' => 'Seed lots result constructed','messageType' => 'INFO'}],'pagination' => {'totalCount' => 479,'pageSize' => 10,'currentPage' => 0,'totalPages' => 48},'datafiles' => []}});

$mech->get_ok('http://localhost:3010/brapi/v2/seedlots/transactions');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'totalPages' => 48,'totalCount' => 479,'pageSize' => 10,'currentPage' => 0},'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::SeedLots','messageType' => 'INFO'},{'message' => 'Transactions result constructed','messageType' => 'INFO'}]},'result' => {'data' => [{'toSeedLotDbId' => '41781','externalReferences' => [],'fromSeedLotDbId' => '41283','additionalInfo' => {},'transactionTimestamp' => '2017-09-18T11:44:50+0000','units' => 'seeds','transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','amount' => '1','transactionDbId' => '41008'},{'amount' => '1','transactionDbId' => '41006','transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','transactionTimestamp' => '2017-09-18T11:44:50+0000','additionalInfo' => {},'units' => 'seeds','fromSeedLotDbId' => '41282','toSeedLotDbId' => '41780','externalReferences' => []},{'amount' => '1','transactionDbId' => '41004','transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','units' => 'seeds','additionalInfo' => {},'transactionTimestamp' => '2017-09-18T11:44:50+0000','fromSeedLotDbId' => '41281','externalReferences' => [],'toSeedLotDbId' => '41779'},{'transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','transactionDbId' => '41002','amount' => '1','fromSeedLotDbId' => '41280','toSeedLotDbId' => '41778','externalReferences' => [],'transactionTimestamp' => '2017-09-18T11:44:50+0000','additionalInfo' => {},'units' => 'seeds'},{'transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','transactionDbId' => '41000','amount' => '1','fromSeedLotDbId' => '41279','externalReferences' => [],'toSeedLotDbId' => '41777','units' => 'seeds','transactionTimestamp' => '2017-09-18T11:44:49+0000','additionalInfo' => {}},{'transactionDbId' => '40998','amount' => '1','transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','additionalInfo' => {},'transactionTimestamp' => '2017-09-18T11:44:49+0000','units' => 'seeds','toSeedLotDbId' => '41776','externalReferences' => [],'fromSeedLotDbId' => '41278'},{'transactionDbId' => '40996','amount' => '1','transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','units' => 'seeds','transactionTimestamp' => '2017-09-18T11:44:49+0000','additionalInfo' => {},'toSeedLotDbId' => '41775','externalReferences' => [],'fromSeedLotDbId' => '41258'},{'transactionTimestamp' => '2017-09-18T11:44:49+0000','additionalInfo' => {},'units' => 'seeds','fromSeedLotDbId' => '41257','toSeedLotDbId' => '41774','externalReferences' => [],'transactionDbId' => '40994','amount' => '1','transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085'},{'transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','transactionDbId' => '40992','amount' => '1','toSeedLotDbId' => '41773','externalReferences' => [],'fromSeedLotDbId' => '41256','transactionTimestamp' => '2017-09-18T11:44:49+0000','additionalInfo' => {},'units' => 'seeds'},{'toSeedLotDbId' => '41772','externalReferences' => [],'fromSeedLotDbId' => '41255','units' => 'seeds','additionalInfo' => {},'transactionTimestamp' => '2017-09-18T11:44:49+0000','transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','transactionDbId' => '40990','amount' => '1'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/seedlots/41310');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::SeedLots'},{'message' => 'Seed lots result constructed','messageType' => 'INFO'}],'pagination' => {'pageSize' => 10,'totalCount' => 1,'currentPage' => 0,'totalPages' => 1},'datafiles' => []},'result' => {'sourceCollection' => undef,'externalReferences' => [],'additionalInfo' => {},'crossDbId' => '','amount' => 1,'createdDate' => undef,'storageLocation' => 'NA','units' => 'seeds','locationDbId' => '25','lastUpdated' => undef,'seedLotDbId' => '41310','seedLotDescription' => '','germplasmDbId' => '38851','programDbId' => '134','seedLotName' => 'new_test_crossP006_001'}});

$mech->get_ok('http://localhost:3010/brapi/v2/seedlots/41305/transactions');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::SeedLots'},{'messageType' => 'INFO','message' => 'Transactions result constructed'}],'pagination' => {'currentPage' => 0,'totalPages' => 1,'totalCount' => 1,'pageSize' => 10}},'result' => {'data' => [{'externalReferences' => [],'additionalInfo' => {},'toSeedLotDbId' => '41305','fromSeedLotDbId' => '38846','units' => 'seeds','transactionDbId' => '40056','transactionDescription' => 'Auto generated seedlot from accession. DbPatch 00085','transactionTimestamp' => '2017-09-18T11:43:59+0000','amount' => '1'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/calls');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::Calls','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Calls result constructed'}],'datafiles' => [],'pagination' => {'totalPages' => 450,'totalCount' => 4500,'currentPage' => 0,'pageSize' => 10}},'result' => {'sepUnphased' => undef,'data' => [{'callSetDbId' => '38878','variantDbId' => 'S10114_185859','genotype' => {'values' => '0'},'additionalInfo' => undef,'variantName' => 'S10114_185859','callSetName' => 'UG120001','phaseSet' => undef,'genotype_likelihood' => undef},{'callSetName' => 'UG120001','variantDbId' => 'S10173_777651','genotype' => {'values' => '0'},'variantName' => 'S10173_777651','callSetDbId' => '38878','additionalInfo' => undef,'phaseSet' => undef,'genotype_likelihood' => undef},{'genotype' => {'values' => '2'},'variantDbId' => 'S10173_899514','callSetName' => 'UG120001','callSetDbId' => '38878','variantName' => 'S10173_899514','additionalInfo' => undef,'genotype_likelihood' => undef,'phaseSet' => undef},{'phaseSet' => undef,'genotype_likelihood' => undef,'additionalInfo' => undef,'variantName' => 'S10241_146006','callSetDbId' => '38878','callSetName' => 'UG120001','variantDbId' => 'S10241_146006','genotype' => {'values' => '0'}},{'variantName' => 'S1027_465354','callSetName' => 'UG120001','phaseSet' => undef,'genotype_likelihood' => undef,'callSetDbId' => '38878','genotype' => {'values' => '2'},'variantDbId' => 'S1027_465354','additionalInfo' => undef},{'additionalInfo' => undef,'phaseSet' => undef,'genotype_likelihood' => undef,'callSetName' => 'UG120001','genotype' => {'values' => '0'},'variantDbId' => 'S10367_21679','variantName' => 'S10367_21679','callSetDbId' => '38878'},{'additionalInfo' => undef,'variantDbId' => 'S1046_216535','genotype' => {'values' => '0'},'callSetDbId' => '38878','genotype_likelihood' => undef,'phaseSet' => undef,'callSetName' => 'UG120001','variantName' => 'S1046_216535'},{'variantName' => 'S10493_191533','callSetDbId' => '38878','callSetName' => 'UG120001','variantDbId' => 'S10493_191533','genotype' => {'values' => '1'},'phaseSet' => undef,'genotype_likelihood' => undef,'additionalInfo' => undef},{'additionalInfo' => undef,'genotype' => {'values' => '2'},'variantDbId' => 'S10493_282956','callSetDbId' => '38878','genotype_likelihood' => undef,'phaseSet' => undef,'callSetName' => 'UG120001','variantName' => 'S10493_282956'},{'genotype' => {'values' => '0'},'variantDbId' => 'S10493_529025','callSetDbId' => '38878','additionalInfo' => undef,'callSetName' => 'UG120001','variantName' => 'S10493_529025','phaseSet' => undef,'genotype_likelihood' => undef}],'sepPhased' => undef,'expandHomozygotes' => undef,'unknownString' => undef}});

$mech->post_ok('http://localhost:3010/brapi/v2/search/calls', ['callSetDbIds' => ['38878']]);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
print STDERR Dumper $response;
$mech->get_ok('http://localhost:3010/brapi/v2/search/calls/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'genotype_likelihood' => undef,'variantDbId' => 'S10114_185859','additionalInfo' => undef,'callSetDbId' => '38878','phaseSet' => undef,'genotype' => {'values' => '0'},'callSetName' => 'UG120001','variantName' => 'S10114_185859'},{'variantDbId' => 'S10173_777651','genotype_likelihood' => undef,'variantName' => 'S10173_777651','callSetDbId' => '38878','phaseSet' => undef,'additionalInfo' => undef,'callSetName' => 'UG120001','genotype' => {'values' => '0'}},{'variantName' => 'S10173_899514','variantDbId' => 'S10173_899514','genotype_likelihood' => undef,'callSetName' => 'UG120001','genotype' => {'values' => '2'},'callSetDbId' => '38878','phaseSet' => undef,'additionalInfo' => undef},{'variantName' => 'S10241_146006','genotype_likelihood' => undef,'variantDbId' => 'S10241_146006','genotype' => {'values' => '0'},'callSetName' => 'UG120001','additionalInfo' => undef,'phaseSet' => undef,'callSetDbId' => '38878'},{'variantDbId' => 'S1027_465354','genotype_likelihood' => undef,'phaseSet' => undef,'callSetDbId' => '38878','additionalInfo' => undef,'callSetName' => 'UG120001','genotype' => {'values' => '2'},'variantName' => 'S1027_465354'},{'callSetDbId' => '38878','phaseSet' => undef,'additionalInfo' => undef,'callSetName' => 'UG120001','genotype' => {'values' => '0'},'variantDbId' => 'S10367_21679','genotype_likelihood' => undef,'variantName' => 'S10367_21679'},{'genotype' => {'values' => '0'},'callSetName' => 'UG120001','additionalInfo' => undef,'callSetDbId' => '38878','phaseSet' => undef,'variantName' => 'S1046_216535','genotype_likelihood' => undef,'variantDbId' => 'S1046_216535'},{'genotype' => {'values' => '1'},'callSetName' => 'UG120001','additionalInfo' => undef,'phaseSet' => undef,'callSetDbId' => '38878','variantName' => 'S10493_191533','genotype_likelihood' => undef,'variantDbId' => 'S10493_191533'},{'genotype_likelihood' => undef,'variantDbId' => 'S10493_282956','variantName' => 'S10493_282956','additionalInfo' => undef,'callSetDbId' => '38878','phaseSet' => undef,'genotype' => {'values' => '2'},'callSetName' => 'UG120001'},{'variantName' => 'S10493_529025','variantDbId' => 'S10493_529025','genotype_likelihood' => undef,'callSetName' => 'UG120001','genotype' => {'values' => '0'},'callSetDbId' => '38878','phaseSet' => undef,'additionalInfo' => undef}]},'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::Results','messageType' => 'INFO'},{'message' => 'search result constructed','messageType' => 'INFO'}],'pagination' => {'currentPage' => 0,'totalPages' => 1,'pageSize' => 10,'totalCount' => 10},'datafiles' => []}});

$mech->get_ok('http://localhost:3010/brapi/v2/callsets/?callSetDbId=38879');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'studyDbId' => ['140','142'],'variantSetDbIds' => ['140p1','142p1'],'sampleDbId' => '38879','additionalInfo' => {'germplasmDbId' => '38879'},'created' => undef,'updated' => undef,'callSetName' => 'UG120002','callSetDbId' => '38879'}]},'metadata' => {'pagination' => {'totalPages' => 1,'pageSize' => 10,'totalCount' => 1,'currentPage' => 0},'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::CallSets','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'CallSets result constructed'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/callsets/38880');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'totalPages' => 1,'pageSize' => 10,'totalCount' => 1,'currentPage' => 0},'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::CallSets','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'CallSets detail result constructed'}]},'result' => {'created' => undef,'sampleDbId' => '38880','callSetName' => 'UG120003','studyDbId' => ['140','142'],'variantSetDbIds' => ['140p1','142p1'],'callSetDbId' => '38880','updated' => undef,'additionalInfo' => {'germplasmDbId' => '38880'}}});

$mech->get_ok('http://localhost:3010/brapi/v2/callsets/38882/calls');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'unknownString' => undef,'sepUnphased' => undef,'expandHomozygotes' => undef,'data' => [{'variantDbId' => 'S10114_185859','phaseSet' => undef,'callSetName' => 'UG120005','variantName' => 'S10114_185859','callSetDbId' => '38882','genotype_likelihood' => undef,'genotype' => {'values' => '1'},'additionalInfo' => undef},{'callSetName' => 'UG120005','phaseSet' => undef,'variantDbId' => 'S10173_777651','callSetDbId' => '38882','variantName' => 'S10173_777651','genotype_likelihood' => undef,'additionalInfo' => undef,'genotype' => {'values' => '0'}},{'callSetName' => 'UG120005','variantDbId' => 'S10173_899514','phaseSet' => undef,'callSetDbId' => '38882','variantName' => 'S10173_899514','genotype_likelihood' => undef,'additionalInfo' => undef,'genotype' => {'values' => '0'}},{'genotype_likelihood' => undef,'additionalInfo' => undef,'genotype' => {'values' => '0'},'callSetName' => 'UG120005','phaseSet' => undef,'variantDbId' => 'S10241_146006','callSetDbId' => '38882','variantName' => 'S10241_146006'},{'genotype_likelihood' => undef,'additionalInfo' => undef,'genotype' => {'values' => '2'},'callSetName' => 'UG120005','phaseSet' => undef,'variantDbId' => 'S1027_465354','callSetDbId' => '38882','variantName' => 'S1027_465354'},{'callSetName' => 'UG120005','phaseSet' => undef,'variantDbId' => 'S10367_21679','callSetDbId' => '38882','variantName' => 'S10367_21679','genotype_likelihood' => undef,'additionalInfo' => undef,'genotype' => {'values' => '0'}},{'genotype_likelihood' => undef,'genotype' => {'values' => '0'},'additionalInfo' => undef,'phaseSet' => undef,'variantDbId' => 'S1046_216535','callSetName' => 'UG120005','variantName' => 'S1046_216535','callSetDbId' => '38882'},{'callSetDbId' => '38882','variantName' => 'S10493_191533','callSetName' => 'UG120005','phaseSet' => undef,'variantDbId' => 'S10493_191533','additionalInfo' => undef,'genotype' => {'values' => '2'},'genotype_likelihood' => undef},{'genotype_likelihood' => undef,'genotype' => {'values' => '2'},'additionalInfo' => undef,'variantDbId' => 'S10493_282956','phaseSet' => undef,'callSetName' => 'UG120005','variantName' => 'S10493_282956','callSetDbId' => '38882'},{'genotype_likelihood' => undef,'additionalInfo' => undef,'genotype' => {'values' => '1'},'callSetName' => 'UG120005','phaseSet' => undef,'variantDbId' => 'S10493_529025','callSetDbId' => '38882','variantName' => 'S10493_529025'}],'sepPhased' => undef},'metadata' => {'datafiles' => [],'pagination' => {'pageSize' => 10,'totalPages' => 100,'currentPage' => 0,'totalCount' => 1000},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::CallSets'},{'messageType' => 'INFO','message' => 'Markerprofiles allelematrix result constructed'}]}});

$mech->post_ok('http://localhost:3010/brapi/v2/search/callsets', ['callSetDbIds' => ['38881']]);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
print STDERR Dumper $response;
$mech->get_ok('http://localhost:3010/brapi/v2/search/callsets/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'additionalInfo' => {'germplasmDbId' => '38881'},'variantSetDbIds' => ['140p1','142p1'],'sampleDbId' => '38881','studyDbId' => ['140','142'],'callSetDbId' => '38881','updated' => undef,'callSetName' => 'UG120004','created' => undef}]},'metadata' => {'pagination' => {'totalPages' => 1,'pageSize' => 10,'currentPage' => 0,'totalCount' => 1},'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Results'},{'messageType' => 'INFO','message' => 'search result constructed'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/variantsets/?studyDbId=140');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response,  {'result' => {'data' => [{'variantSetName' => 'test_genotyping_project - GBS ApeKI genotyping v4','callSetCount' => 9,'additionalInfo' => {},'variantCount' => 500,'referenceSetDbId' => '1','variantSetDbId' => '140p1','availableFormats' => [{'fileFormat' => 'json','dataFormat' => 'json','fileURL' => undef}],'studyDbId' => '140','analysis' => [{'type' => undef,'updated' => undef,'description' => undef,'analysisDbId' => '1','created' => undef,'software' => undef,'analysisName' => 'GBS ApeKI genotyping v4'}]}]},'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::VariantSets','messageType' => 'INFO'},{'message' => 'VariantSets result constructed','messageType' => 'INFO'}],'pagination' => {'totalCount' => 1,'totalPages' => 1,'currentPage' => 0,'pageSize' => 10},'datafiles' => []}});

$mech->get_ok('http://localhost:3010/brapi/v2/variantsets/142p1');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::VariantSets','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'VariantSets result constructed'}],'pagination' => {'totalCount' => 1,'totalPages' => 1,'currentPage' => 0,'pageSize' => 10},'datafiles' => []},'result' => {'studyDbId' => '142','variantCount' => 500,'referenceSetDbId' => '1','variantSetDbId' => '142p1','variantSetName' => 'test_population2 - GBS ApeKI genotyping v4','availableFormats' => [{'dataFormat' => 'json','fileFormat' => 'json','fileURL' => undef}],'analysis' => [{'description' => undef,'type' => undef,'analysisDbId' => '1','analysisName' => 'GBS ApeKI genotyping v4','created' => undef,'updated' => undef,'software' => undef}],'callSetCount' => 280,'additionalInfo' => {}}});

$mech->get_ok('http://localhost:3010/brapi/v2/variantsets/142p1/calls');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::VariantSets','messageType' => 'INFO'},{'message' => 'VariantSets result constructed','messageType' => 'INFO'}],'pagination' => {'totalPages' => 14000,'totalCount' => 140000,'pageSize' => 10,'currentPage' => 0},'datafiles' => []},'result' => {'unknownString' => undef,'expandHomozygotes' => undef,'sepUnphased' => undef,'data' => [{'phaseSet' => undef,'variantName' => 'S10114_185859','additionalInfo' => {},'callSetDbId' => '38878','variantDbId' => 'S10114_185859','genotype' => {'values' => '0'},'callSetName' => 'UG120001','genotype_likelihood' => undef},{'genotype_likelihood' => undef,'callSetDbId' => '38878','additionalInfo' => {},'variantName' => 'S10173_777651','genotype' => {'values' => '0'},'callSetName' => 'UG120001','variantDbId' => 'S10173_777651','phaseSet' => undef},{'phaseSet' => undef,'callSetName' => 'UG120001','genotype' => {'values' => '2'},'variantDbId' => 'S10173_899514','callSetDbId' => '38878','additionalInfo' => {},'variantName' => 'S10173_899514','genotype_likelihood' => undef},{'genotype' => {'values' => '0'},'callSetName' => 'UG120001','variantDbId' => 'S10241_146006','additionalInfo' => {},'callSetDbId' => '38878','variantName' => 'S10241_146006','phaseSet' => undef,'genotype_likelihood' => undef},{'phaseSet' => undef,'genotype_likelihood' => undef,'callSetName' => 'UG120001','genotype' => {'values' => '2'},'variantDbId' => 'S1027_465354','callSetDbId' => '38878','additionalInfo' => {},'variantName' => 'S1027_465354'},{'genotype_likelihood' => undef,'variantName' => 'S10367_21679','additionalInfo' => {},'callSetDbId' => '38878','variantDbId' => 'S10367_21679','callSetName' => 'UG120001','genotype' => {'values' => '0'},'phaseSet' => undef},{'phaseSet' => undef,'callSetName' => 'UG120001','genotype' => {'values' => '0'},'variantDbId' => 'S1046_216535','additionalInfo' => {},'callSetDbId' => '38878','variantName' => 'S1046_216535','genotype_likelihood' => undef},{'genotype' => {'values' => '1'},'callSetName' => 'UG120001','variantDbId' => 'S10493_191533','additionalInfo' => {},'callSetDbId' => '38878','variantName' => 'S10493_191533','phaseSet' => undef,'genotype_likelihood' => undef},{'phaseSet' => undef,'genotype_likelihood' => undef,'variantName' => 'S10493_282956','additionalInfo' => {},'callSetDbId' => '38878','variantDbId' => 'S10493_282956','callSetName' => 'UG120001','genotype' => {'values' => '2'}},{'phaseSet' => undef,'variantDbId' => 'S10493_529025','callSetName' => 'UG120001','genotype' => {'values' => '0'},'variantName' => 'S10493_529025','callSetDbId' => '38878','additionalInfo' => {},'genotype_likelihood' => undef}],'sepPhased' => undef}});

$mech->get_ok('http://localhost:3010/brapi/v2/variantsets/140p1/callsets');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::VariantSets'},{'message' => 'VariantSets result constructed','messageType' => 'INFO'}],'pagination' => {'currentPage' => 0,'pageSize' => 10,'totalPages' => 24,'totalCount' => 235}},'result' => {'data' => [{'additionalInfo' => {},'callSetDbId' => '38878','callSetName' => 'UG120001','created' => undef,'sampleDbId' => '38878','updated' => undef,'studyDbId' => '140','variantSetDbIds' => ['140p1']},{'callSetName' => 'UG120002','callSetDbId' => '38879','additionalInfo' => {},'sampleDbId' => '38879','created' => undef,'studyDbId' => '140','updated' => undef,'variantSetDbIds' => ['140p1']},{'updated' => undef,'studyDbId' => '140','variantSetDbIds' => ['140p1'],'callSetName' => 'UG120003','additionalInfo' => {},'callSetDbId' => '38880','sampleDbId' => '38880','created' => undef},{'updated' => undef,'studyDbId' => '140','variantSetDbIds' => ['140p1'],'callSetName' => 'UG120004','callSetDbId' => '38881','additionalInfo' => {},'sampleDbId' => '38881','created' => undef},{'studyDbId' => '140','updated' => undef,'variantSetDbIds' => ['140p1'],'additionalInfo' => {},'callSetDbId' => '38882','callSetName' => 'UG120005','created' => undef,'sampleDbId' => '38882'},{'studyDbId' => '140','updated' => undef,'variantSetDbIds' => ['140p1'],'additionalInfo' => {},'callSetDbId' => '38883','callSetName' => 'UG120006','sampleDbId' => '38883','created' => undef},{'callSetName' => 'UG120007','additionalInfo' => {},'callSetDbId' => '38884','created' => undef,'sampleDbId' => '38884','updated' => undef,'studyDbId' => '140','variantSetDbIds' => ['140p1']},{'created' => undef,'sampleDbId' => '38885','callSetDbId' => '38885','additionalInfo' => {},'callSetName' => 'UG120008','variantSetDbIds' => ['140p1'],'studyDbId' => '140','updated' => undef},{'studyDbId' => '140','updated' => undef,'variantSetDbIds' => ['140p1'],'callSetDbId' => '38886','additionalInfo' => {},'callSetName' => 'UG120009','sampleDbId' => '38886','created' => undef},{'variantSetDbIds' => ['140p1'],'updated' => undef,'studyDbId' => '140','sampleDbId' => '38887','created' => undef,'callSetDbId' => '38887','additionalInfo' => {},'callSetName' => 'UG120010'}]}} );

#no data for variants
# $mech->get_ok('http://localhost:3010/brapi/v2/variants');
# $response = decode_json $mech->content;
# print STDERR Dumper $response;
# $mech->get_ok('http://localhost:3010/brapi/v2/variantsets/140p1/variants');
# $response = decode_json $mech->content;
# print STDERR Dumper $response;


$mech->post_ok('http://localhost:3010/brapi/v2/search/variantsets', ['variantSetDbIds' => ['143p1']]);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
$mech->get_ok('http://localhost:3010/brapi/v2/search/variantsets/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'availableFormats' => [{'dataFormat' => 'json','fileFormat' => 'json','fileURL' => undef}],'variantSetName' => 'selection_population - GBS ApeKI genotyping v4','analysis' => [{'analysisDbId' => '1','updated' => undef,'description' => undef,'created' => undef,'software' => undef,'type' => undef,'analysisName' => 'GBS ApeKI genotyping v4'}],'additionalInfo' => {},'callSetCount' => 9,'studyDbId' => '143','referenceSetDbId' => '1','variantCount' => 500,'variantSetDbId' => '143p1'}]},'metadata' => {'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Results'},{'messageType' => 'INFO','message' => 'search result constructed'}],'pagination' => {'totalPages' => 1,'totalCount' => 1,'pageSize' => 10,'currentPage' => 0},'datafiles' => []}});

$mech->post_ok('http://localhost:3010/brapi/v2/variantsets/extract', ['variantSetDbIds' => ['142p1']]);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'callSetCount' => 280,'variantSetDbId' => '142p1','variantCount' => 500,'studyDbId' => '142','referenceSetDbId' => '1','variantSetName' => 'test_population2 - GBS ApeKI genotyping v4','availableFormats' => [{'fileURL' => undef,'fileFormat' => 'json','dataFormat' => 'json'}],'additionalInfo' => {},'analysis' => [{'software' => undef,'description' => undef,'created' => undef,'analysisName' => 'GBS ApeKI genotyping v4','type' => undef,'analysisDbId' => '1','updated' => undef}]}]},'metadata' => {'datafiles' => [],'pagination' => {'totalCount' => 1,'totalPages' => 1,'pageSize' => 10,'currentPage' => 0},'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::VariantSets'},{'messageType' => 'INFO','message' => 'VariantSets result constructed'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/trials/');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::Trials','messageType' => 'INFO'},{'message' => 'Trials result constructed','messageType' => 'INFO'}],'pagination' => {'currentPage' => 0,'totalCount' => 1,'totalPages' => 1,'pageSize' => 10},'datafiles' => []},'result' => {'data' => [{'trialDescription' => 'test','programName' => 'test','trialPUI' => undef,'documentationURL' => undef,'datasetAuthorships' => undef,'programDbId' => '134','active' => bless( do{\(my $o = 1)}, 'JSON::PP::Boolean' ),'publications' => undef,'trialDbId' => '134','commonCropName' => 'Cassava','endDate' => undef,'startDate' => undef,'trialName' => 'test','externalReferences' => undef,'additionalInfo' => {},'contacts' => undef}]}} );


$mech->get_ok('http://localhost:3010/brapi/v2/programs');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'datafiles' => [],'pagination' => {'totalCount' => 1,'totalPages' => 1,'pageSize' => 10,'currentPage' => 0},'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Programs'},{'message' => 'Program list result constructed','messageType' => 'INFO'}]},'result' => {'data' => [{'abbreviation' => '','externalReferences' => [],'objective' => 'test','leadPersonDbId' => '','leadPersonName' => '','programDbId' => '134','additionalInfo' => {},'programName' => 'test','documentationURL' => undef,'commonCropName' => 'Cassava'}]}} );

$data = '[{"abbreviation": "P1","additionalInfo": {},"commonCropName": "Tomatillo","documentationURL": "","externalReferences": [],"leadPersonDbId": "50","leadPersonName": "Bob","objective": "Make a better tomatillo","programName": "program3" }, {"abbreviation": "P1","additionalInfo": {},"commonCropName": "Tomatillo","documentationURL": "","externalReferences": [],"leadPersonDbId": "50","leadPersonName": "Bob","objective": "Make a better tomatillo","programName": "Program4" }]';
$mech->post('http://localhost:3010/brapi/v2/programs/', Content => $data);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Programs'},{'message' => '2 Programs were stored.','messageType' => 'INFO'}],'datafiles' => undef,'pagination' => {'totalCount' => 2,'totalPages' => 1,'currentPage' => 0,'pageSize' => 10}},'result' => {}} );

$mech->get_ok('http://localhost:3010/brapi/v2/programs/134');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'pageSize' => 10,'currentPage' => 0,'totalCount' => 1,'totalPages' => 1},'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Programs'},{'message' => 'Program list result constructed','messageType' => 'INFO'}]},'result' => {'leadPersonName' => undef,'programDbId' => '134','externalReferences' => [],'abbreviation' => undef,'leadPersonDbId' => undef,'objective' => 'test','commonCropName' => 'Cassava','documentationURL' => undef,'additionalInfo' => {},'programName' => 'test'}} );

$data = '{ "abbreviation": "P1","additionalInfo": {},"commonCropName": "Tomatillo","documentationURL": "https://breedbase.org/","externalReferences": [],"leadPersonDbId": "fe6f5c50","leadPersonName": "Bob Robertson","objective": "Make a better tomatillo","programName": "Program5" }';
$resp = $ua->put("http://192.168.33.11:3010/brapi/v2/programs/167", Content => $data);
$response = decode_json $resp->{_content};
print STDERR Dumper $response;
is_deeply($response, {'result' => {},'metadata' => {'datafiles' => undef,'pagination' => {'totalPages' => 1,'pageSize' => 10,'currentPage' => 0,'totalCount' => 1},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::Programs','messageType' => 'INFO'},{'messageType' => 'INFO','message' => '1 Program updated.'}]}} );

$mech->post_ok('http://localhost:3010/brapi/v2/search/programs', ['programDbIds'=>'134']);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
$mech->get_ok('http://localhost:3010/brapi/v2/search/programs/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'currentPage' => 0,'pageSize' => 10,'totalPages' => 1,'totalCount' => 1},'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::Results','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'search result constructed'}]},'result' => {'data' => [{'programName' => 'test','documentationURL' => undef,'additionalInfo' => {},'commonCropName' => undef,'objective' => 'test','leadPersonDbId' => '','abbreviation' => '','externalReferences' => [],'programDbId' => '134','leadPersonName' => ''}]}} );

$mech->get_ok('http://localhost:3010/brapi/v2/commoncropnames');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => ['Cassava']},'metadata' => {'datafiles' => [],'pagination' => {'totalPages' => 1,'currentPage' => 0,'pageSize' => 10,'totalCount' => 1},'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::CommonCropNames'},{'messageType' => 'INFO','message' => 'Crops result constructed'}]}});



# #post
# $data = '[ {"active": "true","additionalInfo": {},"commonCropName": "Tomato","contacts": [],"datasetAuthorships": [],"documentationURL": "https://breedbase.org/","endDate": "2020-06-24","externalReferences": [],"programDbId": "134","programName": "test","publications": [],"startDate": "2020-06-24","trialDescription": "General drought resistance trial initiated in Peru","trialName": "Peru Yield Trial 2010","trialPUI": "https://doi.org/101093190"  }]';
# $mech->post('http://localhost:3010/brapi/v2/trials/', Content => $data);
# $response = decode_json $mech->content;
# print STDERR Dumper $response;
# is_deeply($response,        );

# $mech->get_ok('http://localhost:3010/brapi/v2/trials/?trialDbId=134');
# $response = decode_json $mech->content;
# print STDERR Dumper $response;

# $mech->get_ok('http://localhost:3010/brapi/v2/trials/?trialDbId=166');
# $response = decode_json $mech->content;
# print STDERR Dumper $response;

$data = '{ "active": "true","additionalInfo": {},"commonCropName": "Tomato","contacts": [],"datasetAuthorships": [],"documentationURL": "https://breedbase.org/","endDate": "2020-06-24","externalReferences": [],"programDbId": "218","programName": "Tomatillo_Breeding_Program","publications": [],"startDate": "2020-06-24","trialDescription": "Trial initiated in Peru","trialName": "Peru Yield Trial 2020","trialPUI": "https://doi.org/101093190" }';
# $resp = $ua->put("http://192.168.33.11:3010/brapi/v2/trials/166", Content => $data);
# $response = decode_json $resp->{_content};
# print STDERR Dumper $response;

# $mech->get_ok('http://localhost:3010/brapi/v2/trials/134');
# $response = decode_json $mech->content;
# print STDERR Dumper $response;
# is_deeply($response,  {'result' => undef,'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::Trials','messageType' => 'INFO'},{'messageType' => '400','message' => 'The given trialDbId not found.'}],'datafiles' => [],'pagination' => {'pageSize' => 1,'currentPage' => 0,'totalPages' => 0,'totalCount' => 0}}});


$mech->get_ok('http://localhost:3010/brapi/v2/studies/?pageSize=3');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'locationName' => 'test_location','environmentParameters' => undef,'culturalPractices' => undef,'endDate' => undef,'observationUnitsDescription' => undef,'dataLinks' => [],'studyDbId' => '165','observationLevels' => undef,'documentationURL' => '','growthFacility' => undef,'externalReferences' => undef,'studyName' => 'CASS_6Genotypes_Sampling_2015','studyPUI' => undef,'studyType' => 'Preliminary Yield Trial','commonCropName' => 'Cassava','startDate' => undef,'experimentalDesign' => 'RCBD','contacts' => undef,'trialDbId' => '134','seasons' => ['2017'],'license' => '','trialName' => 'test','locationDbId' => '23','studyCode' => '165','studyDescription' => 'Copy of trial with postcomposed phenotypes from cassbase.','lastUpdate' => undef,'active' => JSON::true,'additionalInfo' => {'programName' => 'test','programDbId' => '134'}},{'license' => '','seasons' => ['2014'],'trialDbId' => '134','contacts' => undef,'additionalInfo' => {'programDbId' => '134','programName' => 'test'},'active' => JSON::true,'lastUpdate' => undef,'studyDescription' => 'This trial was loaded into the fixture to test solgs.','studyCode' => '139','locationDbId' => '23','trialName' => 'test','observationLevels' => undef,'studyDbId' => '139','dataLinks' => [],'observationUnitsDescription' => undef,'culturalPractices' => undef,'endDate' => undef,'environmentParameters' => undef,'locationName' => 'test_location','experimentalDesign' => 'Alpha','startDate' => undef,'commonCropName' => 'Cassava','studyType' => 'Clonal Evaluation','studyPUI' => undef,'studyName' => 'Kasese solgs trial','externalReferences' => undef,'growthFacility' => undef,'documentationURL' => ''},{'experimentalDesign' => '','startDate' => undef,'commonCropName' => 'Cassava','studyType' => undef,'studyPUI' => undef,'studyName' => 'new_test_cross','externalReferences' => undef,'growthFacility' => undef,'documentationURL' => '','observationLevels' => undef,'dataLinks' => [],'studyDbId' => '135','observationUnitsDescription' => undef,'endDate' => undef,'culturalPractices' => undef,'environmentParameters' => undef,'locationName' => '','additionalInfo' => {'programDbId' => '134','programName' => 'test'},'active' => JSON::true,'lastUpdate' => undef,'studyDescription' => 'new_test_cross','studyCode' => '135','locationDbId' => undef,'trialName' => 'test','license' => '','contacts' => undef,'seasons' => [undef],'trialDbId' => '134'}]},'metadata' => {'datafiles' => [],'pagination' => {'totalCount' => 6,'totalPages' => 2,'currentPage' => 0,'pageSize' => 3},'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=3'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Studies'},{'messageType' => 'INFO','message' => 'Studies search result constructed'}]}});

$mech->post_ok('http://localhost:3010/brapi/v2/search/studies', ['pageSize'=>'2', 'page'=>'2']);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
$mech->get_ok('http://localhost:3010/brapi/v2/search/studies/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'studyDescription' => 'test trial','studyCode' => '137','lastUpdate' => undef,'observationUnitsDescription' => undef,'experimentalDesign' => 'CRD','environmentParameters' => undef,'externalReferences' => undef,'studyType' => undef,'locationName' => 'test_location','commonCropName' => 'Cassava','growthFacility' => undef,'startDate' => '2017-07-04','studyName' => 'test_trial','trialDbId' => '134','studyPUI' => undef,'license' => '','additionalInfo' => {'programName' => 'test','programDbId' => '134'},'locationDbId' => '23','observationLevels' => undef,'contacts' => undef,'seasons' => ['2014'],'endDate' => '2017-07-21','studyDbId' => '137','trialName' => 'test','dataLinks' => [],'active' => JSON::true,'culturalPractices' => undef,'documentationURL' => ''},{'trialName' => 'test','studyDbId' => '141','documentationURL' => '','culturalPractices' => undef,'dataLinks' => [],'active' => JSON::true,'contacts' => undef,'endDate' => undef,'seasons' => ['2014'],'observationLevels' => undef,'trialDbId' => '134','startDate' => undef,'studyName' => 'trial2 NaCRRI','locationDbId' => '23','additionalInfo' => {'programName' => 'test','programDbId' => '134'},'license' => '','studyPUI' => undef,'commonCropName' => 'Cassava','locationName' => 'test_location','growthFacility' => undef,'externalReferences' => undef,'environmentParameters' => undef,'studyType' => undef,'observationUnitsDescription' => undef,'lastUpdate' => undef,'experimentalDesign' => 'CRD','studyDescription' => 'another trial for solGS','studyCode' => '141'}]},'metadata' => {'pagination' => {'totalCount' => 2,'pageSize' => 10,'totalPages' => 1,'currentPage' => 0},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Results'},{'messageType' => 'INFO','message' => 'search result constructed'}],'datafiles' => []}});
$mech->get_ok('http://localhost:3010/brapi/v2/studies/139');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'totalCount' => 1,'totalPages' => 1,'currentPage' => 0,'pageSize' => 10},'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::Studies','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Studies detail result constructed'}],'datafiles' => []},'result' => {'studyCode' => '139','trialDbId' => '134','environmentParameters' => undef,'externalReferences' => undef,'dataLinks' => [],'commonCropName' => 'Cassava','studyType' => 'Clonal Evaluation','additionalInfo' => {},'documentationURL' => '','endDate' => undef,'studyDescription' => 'This trial was loaded into the fixture to test solgs.','studyName' => 'Kasese solgs trial','locationName' => 'test_location','studyPUI' => undef,'lastUpdate' => undef,'experimentalDesign' => 'Alpha','observationUnitsDescription' => undef,'startDate' => undef,'studyDbId' => '139','observationLevels' => undef,'culturalPractices' => undef,'growthFacility' => undef,'locationDbId' => '23','seasons' => ['2014'],'contacts' => undef,'active' => JSON::true ,'trialName' => 'test','license' => ''}} );

$mech->get_ok('http://localhost:3010/brapi/v2/locations?pageSize=3');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=3'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Locations'},{'messageType' => 'INFO','message' => 'Locations list result constructed'}],'pagination' => {'totalCount' => 4,'totalPages' => 2,'currentPage' => 0,'pageSize' => 3}},'result' => {'data' => [{'instituteName' => '','coordinateUncertainty' => undef,'coordinateDescription' => undef,'locationType' => '','topography' => undef,'abbreviation' => '','instituteAddress' => '','environmentType' => undef,'countryName' => 'United States','countryCode' => 'USA','slope' => undef,'siteStatus' => undef,'locationDbId' => '23','locationName' => 'test_location','exposure' => undef,'externalReferences' => undef,'coordinates' => [{'type' => 'Feature','geometry' => {'coordinates' => ['32.6136','-115.864','109'],'type' => 'Point'}}],'additionalInfo' => {'geodetic datum' => undef,'breeding_program' => '134'},'documentationURL' => undef},{'instituteName' => '','coordinateUncertainty' => undef,'coordinateDescription' => undef,'locationType' => '','topography' => undef,'abbreviation' => '','environmentType' => undef,'instituteAddress' => '','countryName' => 'United States','slope' => undef,'countryCode' => 'USA','siteStatus' => undef,'locationName' => 'Cornell Biotech','locationDbId' => '24','externalReferences' => undef,'exposure' => undef,'coordinates' => [{'type' => 'Feature','geometry' => {'type' => 'Point','coordinates' => ['42.4534','-76.4735','274']}}],'documentationURL' => undef,'additionalInfo' => {'breeding_program' => '134','geodetic datum' => undef}},{'environmentType' => undef,'abbreviation' => '','instituteAddress' => '','locationType' => '','topography' => undef,'coordinateDescription' => undef,'instituteName' => '','coordinateUncertainty' => undef,'coordinates' => [{'type' => 'Feature','geometry' => {'coordinates' => [undef,undef,undef],'type' => 'Point'}}],'documentationURL' => undef,'additionalInfo' => {'geodetic datum' => undef},'locationDbId' => '25','locationName' => 'NA','externalReferences' => undef,'exposure' => undef,'siteStatus' => undef,'countryName' => '','slope' => undef,'countryCode' => ''}]}} );

$data = '[  {    "abbreviation": "L1",    "additionalInfo": {"noaaStationId" : "PALMIRA","programDbId" :"134"},    "coordinateDescription": "North East corner of greenhouse",    "coordinateUncertainty": "20",    "coordinates": {      "geometry": {        "coordinates": [          -76.506042,          42.417373,          123        ],        "type": "Point"      },      "type": "Feature"    },    "countryCode": "PER",    "countryName": "Peru",    "documentationURL": "https://brapi.org",    "environmentType": "Nursery",    "exposure": "Structure, no exposure",    "externalReferences": [      {        "referenceID": "doi:10.155454/12341234",        "referenceSource": "DOI"      },      {        "referenceID": "http://purl.obolibrary.org/obo/ro.owl",        "referenceSource": "OBO Library"      },      {        "referenceID": "75a50e76",        "referenceSource": "Remote Data Collection Upload Tool"      }    ],    "instituteAddress": "71 Pilgrim Avenue Chevy Chase MD 20815",    "instituteName": "Plant Science Institute",    "locationName": "Location 1",    "locationType": "Field",    "siteStatus": "Private",    "slope": "0",    "topography": "Valley"  }]';

$mech->post('http://localhost:3010/brapi/v2/locations/', Content => $data);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'datafiles' => undef,'pagination' => {'currentPage' => 0,'pageSize' => 10,'totalCount' => 1,'totalPages' => 1},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::Locations','messageType' => 'INFO'},{'message' => '1 Locations were saved.','messageType' => 'INFO'}]},'result' => {}});

$mech->get_ok('http://localhost:3010/brapi/v2/locations/23');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'datafiles' => [],'pagination' => {'currentPage' => 0,'totalCount' => 1,'pageSize' => 10,'totalPages' => 1},'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::Locations','messageType' => 'INFO'},{'message' => 'Locations list result constructed','messageType' => 'INFO'}]},'result' => {'data' => [{'locationDbId' => '23','environmentType' => undef,'coordinateUncertainty' => undef,'countryName' => 'United States','abbreviation' => '','countryCode' => 'USA','instituteAddress' => '','topography' => undef,'exposure' => undef,'siteStatus' => undef,'coordinates' => [{'geometry' => {'coordinates' => ['32.6136','-115.864','109'],'type' => 'Point'},'type' => 'Feature'}],'documentationURL' => undef,'instituteName' => '','slope' => undef,'locationType' => '','locationName' => 'test_location','coordinateDescription' => undef,'additionalInfo' => {'geodetic datum' => undef,'breeding_program' => '134'},'externalReferences' => undef}]}} );

$data = '{    "abbreviation": "L2",    "additionalInfo": {"noaaStationId" : "PALMIRA","programDbId" :"134"},    "coordinateDescription": "North East corner of greenhouse",    "coordinateUncertainty": "20",    "coordinates": {      "geometry": {        "coordinates": [          -76.506042,          42.417373,          123        ],        "type": "Point"      },      "type": "Feature"    },    "countryCode": "PER",    "countryName": "Peru",    "documentationURL": "https://brapi.org",    "environmentType": "Nursery",    "exposure": "Structure, no exposure",    "externalReferences": [      {        "referenceID": "doi:10.155454/12341234",        "referenceSource": "DOI"      },      {        "referenceID": "http://purl.obolibrary.org/obo/ro.owl",        "referenceSource": "OBO Library"      },      {        "referenceID": "75a50e76",        "referenceSource": "Remote Data Collection Upload Tool"      }    ],    "instituteAddress": "71 Pilgrim Avenue Chevy Chase MD 20815",    "instituteName": "Plant Science Institute",    "locationName": "Location 2",    "locationType": "Field",    "siteStatus": "Private",    "slope": "0",    "topography": "Valley"  }';

$resp = $ua->put("http://192.168.33.11:3010/brapi/v2/locations/25", Content => $data);
$response = decode_json $resp->{_content};
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'pageSize' => 10,'currentPage' => 0,'totalCount' => 1,'totalPages' => 1},'datafiles' => undef,'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Locations'},{'message' => '1 Locations were saved.','messageType' => 'INFO'}]},'result' => {}});

$mech->post_ok('http://localhost:3010/brapi/v2/search/locations', ['locationDbIds'=>['25','27']]);
$response = decode_json $mech->content;
$searchId = $response->{result} ->{searchResultDbId};
$mech->get_ok('http://localhost:3010/brapi/v2/search/locations/'. $searchId);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'countryCode' => 'PER','coordinateDescription' => undef,'abbreviation' => 'L2','additionalInfo' => {'breeding_program' => '134','noaa_station_id' => 'PALMIRA','geodetic datum' => undef},'countryName' => 'Peru','locationType' => 'Field','instituteAddress' => '','topography' => undef,'locationDbId' => '25','environmentType' => undef,'siteStatus' => undef,'slope' => undef,'documentationURL' => undef,'coordinateUncertainty' => undef,'locationName' => 'Location 2','externalReferences' => undef,'instituteName' => '','coordinates' => [{'type' => 'Feature','geometry' => {'type' => 'Point','coordinates' => ['-76.506','42.4174',123]}}],'exposure' => undef},{'coordinates' => [{'type' => 'Feature','geometry' => {'coordinates' => ['-76.506','42.4174',123],'type' => 'Point'}}],'exposure' => undef,'instituteName' => '','externalReferences' => undef,'locationName' => 'Location 1','coordinateUncertainty' => undef,'slope' => undef,'documentationURL' => undef,'environmentType' => undef,'siteStatus' => undef,'locationDbId' => '27','topography' => undef,'instituteAddress' => '','locationType' => 'Field','countryName' => 'Peru','additionalInfo' => {'breeding_program' => '134','geodetic datum' => undef,'noaa_station_id' => 'PALMIRA'},'abbreviation' => 'L1','coordinateDescription' => undef,'countryCode' => 'PER'}]},'metadata' => {'datafiles' => [],'pagination' => {'pageSize' => 10,'totalPages' => 1,'currentPage' => 0,'totalCount' => 2},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Results'},{'messageType' => 'INFO','message' => 'search result constructed'}]}} );

$mech->get_ok('http://localhost:3010/brapi/v2/people');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'personDbId' => '40','mailingAddress' => undef,'userID' => 'johndoe','firstName' => 'John','emailAddress' => undef,'description' => undef,'phoneNumber' => undef,'additionalInfo' => {'country' => undef},'lastName' => 'Doe','externalReferences' => {'referenceSource' => undef,'referenceID' => undef},'middleName' => undef},{'middleName' => undef,'externalReferences' => {'referenceID' => undef,'referenceSource' => undef},'lastName' => 'Doe','additionalInfo' => {'country' => undef},'phoneNumber' => undef,'description' => undef,'emailAddress' => undef,'userID' => 'janedoe','firstName' => 'Jane','mailingAddress' => undef,'personDbId' => '41'},{'lastName' => 'Sanger','middleName' => undef,'emailAddress' => undef,'description' => undef,'phoneNumber' => undef,'additionalInfo' => {'country' => undef},'externalReferences' => {'referenceID' => undef,'referenceSource' => undef},'personDbId' => '42','mailingAddress' => undef,'firstName' => 'Fred','userID' => 'freddy'}]},'metadata' => {'pagination' => {'pageSize' => 10,'totalCount' => 3,'totalPages' => 1,'currentPage' => 0},'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::People'},{'message' => 'People result constructed','messageType' => 'INFO'}]}});

$mech->get_ok('http://localhost:3010/brapi/v2/people/41');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'mailingAddress' => undef,'middleName' => undef,'personDbId' => '41','additionalInfo' => {'country' => undef},'externalReferences' => {'referenceID' => undef,'referenceSource' => undef},'description' => 'Organization: ','lastName' => 'Doe','firstName' => 'Jane','userID' => 'janedoe','phoneNumber' => undef,'emailAddress' => undef},'metadata' => {'datafiles' => [],'pagination' => {'pageSize' => 10,'currentPage' => 0,'totalCount' => 1,'totalPages' => 1},'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::People','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'People result constructed'}]}} );



$data = '[
    {
    "accessionNumber": "fem_maleProgeny_002new",
    "acquisitionDate": "2018-01-01",
    "additionalInfo": {},
    "biologicalStatusOfAccessionCode": "420",
    "biologicalStatusOfAccessionDescription": "Genetic stock",
    "breedingMethodDbId": "ffcce7ef", 
    "collection": "Rice Diversity Panel 1 (RDP1)", 
    "commonCropName": "Maize", 							
    "countryOfOriginCode": "BES",
    "defaultDisplayName": "fem_maleProgeny_002",
    "documentationURL": "https://breedbase.org/",		
    "donors": [
      {
        "donorAccessionNumber": "A0000123",
        "donorInstituteCode": "PER001",						
        "germplasmPUI": "http://pui.per/accession/A0000003"	
      }
    ],
    "externalReferences": [], 				
    "genus": "Aspergillus",					
    "germplasmName": "test_Germplasm9",
    "germplasmOrigin": [					
      {
        "coordinateUncertainty": "20",
        "coordinates": {
          "geometry": {
            "coordinates": [
              -76.506042,
              42.417373,
              123
            ],
            "type": "Point"
          },
          "type": "Feature"
        }
      }
    ],
    "germplasmPUI": "http://pui.per/accession/fem_maleProgeny_002",		
    "germplasmPreprocessing": "EO:0007210; transplanted from study 2351 observation unit ID: pot:894",		
    "instituteCode": "PER001",
    "instituteName": "BTI",
    "pedigree": "A0000001/A0000002",	
    "seedSource": "A0000001/A0000002",	
    "seedSourceDescription": "Branches were collected from a 10-year-old",
    "species": "Solanum lycopersicum",
    "speciesAuthority": "Smith, 1822", 			
    "storageTypes": [
      {
        "code": "20",
        "description": "Field collection"
      },
      {
        "code": "10",
        "description": "Field collection"
      }
    ],
    "subtaxa": "Aspergillus fructus A",		
    "subtaxaAuthority": "Smith, 1822",		
    "synonyms": [
      {
        "synonym": "variety_1",				
        "type": "Pre-Code"
      }
    ],
    "taxonIds": [
      {
        "sourceName": "NCBI",				
        "taxonId": "2026747"
      }
    ]
  }
]'; 

$mech->post('http://localhost:3010/brapi/v2/germplasm/', Content => $data);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response,  {'metadata' => {'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'message' => 'Loading CXGN::BrAPI::v2::Germplasm','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Germplasm saved'}],'pagination' => {'totalPages' => 1,'currentPage' => 0,'pageSize' => 10,'totalCount' => 1}},'result' => {'data' => [{'instituteCode' => 'PER001','additionalInfo' => undef,'speciesAuthority' => undef,'defaultDisplayName' => 'fem_maleProgeny_002','collection' => undef,'germplasmName' => 'test_Germplasm9','acquisitionDate' => '2018-01-01','genus' => 'Lycopersicon','synonyms' => [{'type' => undef,'synonym' => 'variety_1'}],'externalReferences' => [],'donors' => [{'germplasmPUI' => 'PER001','donorInstituteCode' => 'PER001','donorAccessionNumber' => 'A0000123'}],'biologicalStatusOfAccessionCode' => '420','instituteName' => 'BTI','subtaxa' => undef,'countryOfOriginCode' => 'BES','biologicalStatusOfAccessionDescription' => undef,'germplasmPUI' => 'http://pui.per/accession/fem_maleProgeny_002,localhost/stock/41783/view','species' => 'Solanum lycopersicum','taxonIds' => [],'storageTypes' => [{'code' => '20','description' => undef}],'germplasmPreprocessing' => undef,'germplasmOrigin' => [],'accessionNumber' => 'fem_maleProgeny_002new','breedingMethodDbId' => undef,'commonCropName' => 'tomato','germplasmDbId' => '41783','seedSource' => 'A0000001/A0000002','pedigree' => 'NA/NA','documentationURL' => 'http://pui.per/accession/fem_maleProgeny_002,localhost/stock/41783/view','seedSourceDescription' => 'A0000001/A0000002','subtaxaAuthority' => undef}]}});

$data = '{
    "accessionNumber": "fem_maleProgeny_002",
    "acquisitionDate": "2018-01-07",
    "additionalInfo": {},
    "biologicalStatusOfAccessionCode": "4207",
    "biologicalStatusOfAccessionDescription": "Genetic stock",
    "breedingMethodDbId": "ffcce7ef", 
    "collection": "Rice Diversity Panel 1 (RDP1)", 
    "commonCropName": "Maize", 							
    "countryOfOriginCode": "BES7",
    "defaultDisplayName": "fem_maleProgeny_0027",
    "documentationURL": "https://wiki.brapi.org7",		
    "donors": [
      {
        "donorAccessionNumber": "A0000123",
        "donorInstituteCode": "PER0017",						
        "germplasmPUI": "http://accession/A00000037"	
      }
    ],
    "externalReferences": [], 				
    "genus": "Aspergillus7",					
    "germplasmName": "test_Germplasm",
    "germplasmOrigin": [					
      {
        "coordinateUncertainty": "20",
        "coordinates": {
          "geometry": {
            "coordinates": [
              -76.506042,
              42.417373,
              123
            ],
            "type": "Point"
          },
          "type": "Feature"
        }
      }
    ],
    "germplasmPUI": "http://accession/fem_maleProgeny_0027",		
    "germplasmPreprocessing": "EO:0007210; transplanted from study 2351 observation unit ID: pot:894",		
    "instituteCode": "PER0017",
    "instituteName": "BTI Ithaca",
    "pedigree": "A0000001/A00000027",	
    "seedSource": "A0000001/A00000027",	
    "seedSourceDescription": "Branches were collected from a 10-year-old tree growing in a progeny trial established in a loamy brown earth soil7.",
    "species": "Solanum lycopersicum",
    "speciesAuthority": "Smith, 1822", 			
    "storageTypes": [
      {
        "code": "207",
        "description": "Field collection"
      },
      {
        "code": "10",
        "description": "Field collection"
      }
    ],
    "subtaxa": "Aspergillus fructus A",		
    "subtaxaAuthority": "Smith, 1822",		
    "synonyms": [
      {
        "synonym": "variety_17",				
        "type": "Pre-Code"
      }
    ],
    "taxonIds": [
      {
        "sourceName": "NCBI",				
        "taxonId": "2026747"
      }
    ]
  }';

$resp = $ua->put("http://192.168.33.11:3010/brapi/v2/germplasm/41279", Content => $data);
$response = decode_json $resp->{_content};
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'pagination' => {'totalCount' => 1,'currentPage' => 0,'pageSize' => 10,'totalPages' => 1},'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Germplasm'},{'message' => 'Germplasm updated','messageType' => 'INFO'}]},'result' => {'pedigree' => 'NA/NA','instituteCode' => 'PER0017','species' => 'Manihot esculenta','externalReferences' => [],'collection' => undef,'commonCropName' => undef,'breedingMethodDbId' => undef,'speciesAuthority' => undef,'donors' => [{'donorAccessionNumber' => 'A0000123','germplasmPUI' => 'PER0017','donorInstituteCode' => 'PER0017'}],'seedSource' => 'A0000001/A00000027','seedSourceDescription' => 'A0000001/A00000027','acquisitionDate' => '2018-01-07','genus' => 'Manihot','germplasmPreprocessing' => undef,'accessionNumber' => 'fem_maleProgeny_002','germplasmPUI' => 'http://accession/fem_maleProgeny_0027,192.168.33.11/stock/41279/view','documentationURL' => 'http://accession/fem_maleProgeny_0027,192.168.33.11/stock/41279/view','synonyms' => [{'type' => undef,'synonym' => 'variety_17'}],'biologicalStatusOfAccessionCode' => '4207','instituteName' => 'BTI Ithaca','additionalInfo' => undef,'germplasmName' => 'IITA-TMS-IBA30572','subtaxa' => undef,'biologicalStatusOfAccessionDescription' => undef,'germplasmOrigin' => [],'taxonIds' => [],'germplasmDbId' => '41279','storageTypes' => [{'code' => '207','description' => undef}],'defaultDisplayName' => 'IITA-TMS-IBA30572','countryOfOriginCode' => 'BES7','subtaxaAuthority' => undef}});

$data = '[
  {
    "active": "true",
    "additionalInfo": {},
    "commonCropName": "Grape",
    "contacts": [],
    "culturalPractices": "Irrigation was applied according needs during summer to prevent water stress.",
    "dataLinks": [],
    "documentationURL": "https://breedbase.org/",
    "endDate": "2020-06-12T22:05:35.680Z",
    "environmentParameters": [],
    "experimentalDesign": {
      "PUI": "RCBD",
      "description": "Random"
    },
    "externalReferences": [],
    "growthFacility": { },
    "lastUpdate": {},
    "license": "MIT License",
    "locationDbId": "23",
    "locationName": "test_location",
    "observationLevels": [],
    "observationUnitsDescription": "Observation units",
    "seasons": [
      "2018"
    ],
    "startDate": "2020-06-12T22:05:35.680Z",
    "studyCode": "Grape_Yield_Spring_2018",
    "studyDescription": "This is a yield study for Spring 2018",
    "studyName": "Observation at Kenya 1",
    "studyPUI": "doi:10.155454/12349537312",
    "studyType": "phenotyping_trial",
    "trialDbId": "134",
    "trialName": "test"
  }
]';

$mech->post('http://localhost:3010/brapi/v2/studies', Content => $data);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'metadata' => {'datafiles' => [],'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Studies'},{'messageType' => 'INFO','message' => 'Studies result constructed'}],'pagination' => {'currentPage' => 0,'pageSize' => 10,'totalCount' => 1,'totalPages' => 1}},'result' => {'data' => [{'experimentalDesign' => 'RCBD','license' => '','environmentParameters' => undef,'studyType' => 'phenotyping_trial','studyDbId' => '168','dataLinks' => [],'startDate' => undef,'locationDbId' => '23','externalReferences' => undef,'seasons' => ['2018'],'additionalInfo' => {'programName' => 'test','programDbId' => '134'},'trialName' => 'test','active' => bless( do{\(my $o = 1)}, 'JSON::PP::Boolean' ),'studyDescription' => 'This is a yield study for Spring 2018','studyName' => 'Observation at Kenya 1','documentationURL' => '','locationName' => 'test_location','contacts' => undef,'culturalPractices' => undef,'growthFacility' => undef,'studyPUI' => undef,'studyCode' => '168','observationLevels' => undef,'endDate' => undef,'lastUpdate' => undef,'commonCropName' => 'Cassava','observationUnitsDescription' => undef,'trialDbId' => '134'}]}});

$data = '{
  "active": true,
  "additionalInfo": {},
  "commonCropName": "Grape",
  "contacts": [],
  "culturalPractices": "Irrigation was applied according needs during summer to prevent water stress.",
  "dataLinks": [],
  "documentationURL": "http://breedbase.org",
  "endDate": "2018-01-01",
  "environmentParameters": [
    {
      "description": "the soil type was clay",
      "parameterName": "soil type",
      "parameterPUI": "PECO:0007155",
      "unit": "pH",
      "unitPUI": "PECO:0007059",
      "value": "clay soil",
      "valuePUI": "ENVO:00002262"
    }
  ],
  "experimentalDesign": {
    "PUI": "CO_715:0000145",
    "description": "Lines were repeated twice at each location using a complete block design. In order to limit competition effects, each block was organized into four sub-blocks corresponding to earliest groups based on a prior information."
  },
  "externalReferences": [],
  "growthFacility": {
    "PUI": "CO_715:0000162",
    "description": "field environment condition, greenhouse"
  },
  "lastUpdate": {
    "timestamp": "2018-01-01T14:47:23-0600",
    "version": "1.2.3"
  },
  "license": "MIT License",
  "locationDbId": "23",
  "locationName": "test_location",
  "observationLevels": [],
  "observationUnitsDescription": "Observation units consisted in individual plots themselves consisting of a row of 15 plants at a density of approximately six plants per square meter.",
  "seasons": [
    "Spring_2018"
  ],
  "startDate": "2018-01-01",
  "studyCode": "Grape_Yield_Spring_2018",
  "studyDescription": "This is a yield study for Spring 2018",
  "studyName": "INRAs Walnut Genetic Resources Observation at Kenya modified",
  "studyPUI": "doi:10.155454/12349537312",
  "studyType": "phenotyping_trial",
  "trialDbId": "134",
  "trialName": "test"
}';

$resp = $ua->put("http://192.168.33.11:3010/brapi/v2/studies/257", Content => $data);
$response = decode_json $resp->{_content};
print STDERR Dumper $response;
is_deeply($response, {'result' => undef,'metadata' => {'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Studies'},{'messageType' => '400','message' => 'You need to be associated with breeding program  to change the details of this trial.'}],'pagination' => {'pageSize' => 1,'currentPage' => 0,'totalCount' => 0,'totalPages' => 0},'datafiles' => []}});


$data = '[  {"additionalInfo": {},"copyright": "Copyright 2018 Bob","description": "Tomatoes","descriptiveOntologyTerms": [],"externalReferences": [],"imageFileName": "image_00G00231a.jpg","imageFileSize": 50000,"imageHeight": 550,"imageLocation": {  "geometry": {"coordinates": [  -76.506042,  42.417373,  9],"type": "Point"  },  "type": "Feature"},"imageName": "Tomato Imag-10","imageTimeStamp": "2020-06-17T16:20:00.217Z","imageURL": "https://breedbase.org/images/tomato","imageWidth": 700,"mimeType": "image/jpeg","observationDbIds": [],"observationUnitDbId": "38842"  }]';
$mech->post('http://localhost:3010/brapi/v2/images', Content => $data);
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response->{metadata}, {'status' => [{'message' => 'BrAPI base call found with page=0, pageSize=10','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Loading CXGN::BrAPI::v2::Images'},{'message' => 'Image metadata stored','messageType' => 'INFO'}],'datafiles' => undef,'pagination' => {'pageSize' => 10,'totalPages' => 1,'currentPage' => 0,'totalCount' => 1}});

$data = '{  "additionalInfo": {},  "copyright": "Copyright 2019 Bob",  "description": "picture of a tomato",  "descriptiveOntologyTerms": [],  "externalReferences": [],  "imageFileName": "image_0AA0231.jpg",  "imageFileSize": 50000,  "imageHeight": 550,  "imageLocation": {"geometry": {  "coordinates": [-76.506042,42.417373,123  ],  "type": "Point"},"type": "Feature"  },  "imageName": "Tomato Image-x1",  "imageTimeStamp": "2020-06-17T16:08:42.015Z",  "imageURL": "https://breedbase.org/images/tomato",  "imageWidth": 700,  "mimeType": "image/jpeg",  "observationDbIds": [],  "observationUnitDbId": "38843"}';

$resp = $ua->put("http://192.168.33.11:3010/brapi/v2/images/2425", Content => $data);
$response = decode_json $resp->{_content};
print STDERR Dumper $response;
is_deeply($response->{result}->{data}[0]->{observationUnitDbId} , '38843');
my $image_timestamp = $response->{result}->{data}[0]->{imageTimeStamp} ;

$mech->get_ok('http://localhost:3010/brapi/v2/images');
$response = decode_json $mech->content;
print STDERR Dumper $response;
is_deeply($response, {'result' => {'data' => [{'descriptiveOntologyTerms' => [],'imageWidth' => undef,'imageLocation' => {'type' => '','geometry' => {'type' => '','coordinates' => []}},'imageFileName' => 'image_0AA0231.jpg','imageFileSize' => undef,'imageURL' => 'localhost/data/images/image_files/XX/XX/XX/XX/XXXXXXXXXXXXXXXXXXXXXXXX/medium.jpg','description' => 'picture of a tomato','copyright' => 'janedoe 2020','imageDbId' => '2425','imageTimeStamp' => $image_timestamp,'mimeType' => 'image/jpeg','additionalInfo' => {'observationLevel' => 'accession','tags' => [],'observationUnitName' => 'test_accession4'},'imageHeight' => undef,'observationUnitDbId' => '38843','observationDbIds' => [],'imageName' => 'Tomato Image-x1','externalReferences' => []}]},'metadata' => {'datafiles' => [],'status' => [{'messageType' => 'INFO','message' => 'BrAPI base call found with page=0, pageSize=10'},{'message' => 'Loading CXGN::BrAPI::v2::Images','messageType' => 'INFO'},{'messageType' => 'INFO','message' => 'Image search result constructed'}],'pagination' => {'currentPage' => 0,'totalCount' => 1,'totalPages' => 1,'pageSize' => 10}}} );

done_testing();
