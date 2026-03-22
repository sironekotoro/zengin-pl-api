use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/../lib";

use Test::More;

BEGIN {
    use_ok('Zengin::PL::API');
}

my $app = do "$FindBin::Bin/../app.psgi";
ok($app && ref $app eq 'CODE', 'app.psgi returns a PSGI app')
    or diag($@ || 'app.psgi did not return a coderef');

done_testing;
