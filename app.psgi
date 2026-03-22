use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";

use Zengin::PL::API;

my $app = Zengin::PL::API->new->to_app;

$app;
