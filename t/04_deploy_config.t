use strict;
use warnings;
use Test::More;

my $workflow_path = '.github/workflows/deploy.yml';
open my $fh, '<', $workflow_path
    or die "Cannot open $workflow_path: $!";
my $workflow = do { local $/; <$fh> };
close $fh;

like(
    $workflow,
    qr/^  MAX_INSTANCES: '3'$/m,
    'Cloud Run maximum instance count is explicit and conservative',
);

like(
    $workflow,
    qr/^          flags: '--max=\$\{\{ env\.MAX_INSTANCES \}\}'$/m,
    'deploy action applies the service-level maximum instance count',
);

done_testing;
