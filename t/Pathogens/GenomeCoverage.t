#!/usr/bin/env perl
use strict;
use warnings;
use lib "./module"; # test module (remove)

BEGIN {
    use Test::Most ;
    use_ok('Pathogens::Parser::GenomeCoverage');
}

ok my $gc = Pathogens::Parser::GenomeCoverage->new( bamcheck => 't/data/small_slice.bam.bc',
						    ref_size => 300 ), 'creates instance of object';

# test errors
ok my $gc_err = Pathogens::Parser::GenomeCoverage->new( bamcheck => 'a_file_that_does_not_exist' ), 'create instance for nonfile';
throws_ok {$gc_err->coverage()} qr/GenomeCoverage::coverage/,'coverage throws for nonexistent file';
throws_ok {$gc_err->ref_size('xxx')} qr/GenomeCoverage::ref_size/,'coverage throws for garbage input';

# test coverage()
ok my @cover_bins = $gc->coverage(), 'coverage default runs';
is $cover_bins[0], '248', 'coverage default gives expected result';
ok @cover_bins = $gc->coverage(1,50,100,150,200), 'coverage for bins runs'; 
is join(',',@cover_bins), '248,221,194,165,145', 'coverage for bins gives expected result';
ok @cover_bins = $gc->coverage(1,150,100,50,200), 'coverage for unsorted bins runs'; 
is join(',',@cover_bins), '248,165,194,221,145', 'coverage for unsorted bins gives expected result';
#throws_ok {$sam_util->coverage('a_file_that_does_not_exist')} qr/VertRes::Utils::Sam::coverage/,'coverage throws for nonexistent file';
#throws_ok {$sam_util->coverage($not_bam)} qr/VertRes::Utils::Sam::coverage/,'coverage throws for bad file';

# test coverage_depth()
ok my ($cover_bases,$depth_mean,$depth_sd) = $gc->coverage_depth(), 'coverage_depth runs';
is sprintf("%d,%.2f,%.2f",$cover_bases,$depth_mean,$depth_sd),'248,167.00,118.05','coverage_depth gives expected result';
ok $gc->ref_size(200), 'Set ref_size too low.';
throws_ok {$gc->coverage_depth} qr/Total bases found by bamcheck exceeds size of reference sequence./,'coverage_depth throws for low ref_size';


#throws_ok {$sam_util->coverage_depth($cover_bam,'foobar')} qr/VertRes::Utils::Sam::coverage_depth/, 'coverage_depth throws for garbage input';
#throws_ok {$sam_util->coverage_depth($cover_bam,0)} qr/VertRes::Utils::Sam::coverage_depth/, 'coverage_depth throws for ref size = zero';
#throws_ok {$sam_util->coverage_depth($cover_bam,200)} qr/VertRes::Utils::Sam::coverage_depth/, 'coverage_depth throws for ref size too small';
#throws_ok {$sam_util->coverage_depth('a_file_that_does_not_exist',300)} qr/VertRes::Utils::Sam::coverage_depth/, 'coverage_depth throws for nonexistent file';
#throws_ok {$sam_util->coverage_depth($not_bam,300)} qr/VertRes::Utils::Sam::coverage_depth/, 'coverage_depth throws for bad file';



done_testing();
exit;
