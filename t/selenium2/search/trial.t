
use strict;

use lib 't/lib';

use Test::More;
use SGN::Test::WWW::WebDriver;

my $d = SGN::Test::WWW::WebDriver->new();

$d->get_ok('/search/trials');

ok($d->driver->get_page_source()=~/test_trial/, "find trial search result content");

ok($d->driver->get_page_source()=~/2014/, "find trial year in trial search results");

my $trial_search_input = $d->find_element("//div[\@id=\"search_results_filter\"]/descendant::label/descendant::input", "xpath");

$trial_search_input->send_keys("Kasese");

sleep(2);

my $page_source = $d->driver->get_page_source();

ok($page_source=~m/loaded into the fixture to test solgs/, "find trial description");

sleep(2);

ok($page_source!~m/test_trial/, "Do not find the test trial now");

sleep(2);

done_testing();

