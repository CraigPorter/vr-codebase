=head1 NAME

VertRes::Pipelines::TrackQC_Bam - pipeline for QC of bam files

=head1 SYNOPSIS

See /lustre/scratch102/conf/pipeline.conf and /lustre/scratch102/conf/qc-g1k-meta.conf
for an example.

=cut

package VertRes::Pipelines::TrackQC_Bam;
use base qw(VertRes::Pipeline);

use strict;
use warnings;
use LSF;
use VertRes::Utils::GTypeCheck;
use VRTrack::VRTrack;
use VRTrack::Lane;
use VRTrack::Mapstats;

our @actions =
(
    # Takes care of merging of the (possibly) multiple bam files
    {
        'name'     => 'rename_and_merge',
        'action'   => \&rename_and_merge,
        'requires' => \&rename_and_merge_requires, 
        'provides' => \&rename_and_merge_provides,
    },

    # Runs glf to check the genotype.
    {
        'name'     => 'check_genotype',
        'action'   => \&check_genotype,
        'requires' => \&check_genotype_requires, 
        'provides' => \&check_genotype_provides,
    },

    # Creates some QC graphs and generate some statistics.
    {
        'name'     => 'stats_and_graphs',
        'action'   => \&stats_and_graphs,
        'requires' => \&stats_and_graphs_requires, 
        'provides' => \&stats_and_graphs_provides,
    },

    # Checks the generated stats and attempts to auto pass or fail the lane.
    {
        'name'     => 'auto_qc',
        'action'   => \&auto_qc,
        'requires' => \&auto_qc_requires, 
        'provides' => \&auto_qc_provides,
    },

    # Writes the QC status to the tracking database.
    {
        'name'     => 'update_db',
        'action'   => \&update_db,
        'requires' => \&update_db_requires, 
        'provides' => \&update_db_provides,
    },
);

our $options = 
{
    # Executables
    'blat'            => '/software/pubseq/bin/blat',
    'gcdepth_R'       => '/software/vertres/bin/gcdepth.R',
    'glf'             => '/nfs/sf8/G1K/bin/glf',
    'mapviewdepth'    => 'mapviewdepth_sam',
    'samtools'        => 'samtools',
    'clean_fastqs'    => 0,

    'adapters'        => '/software/pathogen/projects/protocols/ext/solexa-adapters.fasta',
    'bsub_opts'       => "-q normal -M5000000 -R 'select[type==X86_64 && mem>5000] rusage[mem=5000,thouio=1]'",
    'bsub_opts_merge' => "-q normal -M5000000 -R 'select[type==X86_64 && mem>5000] rusage[mem=5000,thouio=5]'",
    'bwa_clip'        => 20,
    'gc_depth_bin'    => 20000,
    'gtype_confidence'=> 5.0,
    'mapstat_id'      => 'mapstat_id.txt',
    'sample_dir'      => 'qc-sample',
    'stats'           => '_stats',
    'stats_detailed'  => '_detailed-stats.txt',
    'stats_dump'      => '_stats.dump',
    'chr_regex'       => '^(?:\d+|X|Y)$',

    auto_qc =>
    {
        gtype_regex  => qr/^confirmed$/,
        mapped_bases => 80,
        error_rate   => 0.02,
        inserts_peak_win    => 25,
        inserts_within_peak => 80,
    },
};


# --------- OO stuff --------------

=head2 new

        Example    : my $qc = VertRes::Pipelines::TrackQC_Bam->new( 'sample_dir'=>'dir', 'sample_size'=>1e6 );
        Options    : See Pipeline.pm for general options.

                    # Executables
                    blat            .. blat executable
                    gcdepth_R       .. gcdepth R script
                    glf             .. glf executable
                    mapviewdepth    .. mapviewdepth executable
                    samtools        .. samtools executable

                    # Options specific to TrackQC
                    adapters        .. the location of .fa with adapter sequences
                    assembly        .. e.g. NCBI36
                    bsub_opts       .. LSF bsub options for jobs
                    bsub_opts_merge .. LSF bsub options for the rename_and_merge task (thouio=50)
                    bwa_clip        .. The value to the 'bwa aln -q ' command.
                    bwa_ref         .. the prefix to reference files, as required by bwa
                    clean_fastqs    .. If set, .fastq files will be deleted as the last step in update_db
                    fa_ref          .. the reference sequence in fasta format
                    fai_ref         .. the index to fa_ref generated by samtools faidx
                    gc_depth_bin    .. the bin size for the gc-depth graph
                    gtype_confidence.. the minimum expected glf likelihood ratio
                    mapstat_id      .. if the file exists, use the id inside for the vrtrack mapstat
                    paired          .. is the lane from paired-end sequencing?
                    snps            .. genotype file generated by hapmap2bin from glftools
                    sample_dir      .. where to put subsamples
                    stats_ref       .. e.g. /path/to/NCBI36.stats
                    auto_qc         .. hash with the keys gtype_regex,mapped_bases,error_rate,inserts_peak_win,inserts_within_peak

=cut

sub VertRes::Pipelines::TrackQC_Bam::new 
{
    my ($class, @args) = @_;
    my $self = $class->SUPER::new(%$options,'actions'=>\@actions,@args);
    $self->write_logs(1);

    if ( !$$self{gcdepth_R} ) { $self->throw("Missing the option gcdepth_R.\n"); }
    if ( !$$self{glf} ) { $self->throw("Missing the option glf.\n"); }
    if ( !$$self{mapviewdepth} ) { $self->throw("Missing the option mapviewdepth.\n"); }
    if ( !$$self{samtools} ) { $self->throw("Missing the option samtools.\n"); }
    if ( !$$self{fa_ref} ) { $self->throw("Missing the option fa_ref.\n"); }
    if ( !$$self{fai_ref} ) { $self->throw("Missing the option fai_ref.\n"); }
    if ( !$$self{gc_depth_bin} ) { $self->throw("Missing the option gc_depth_bin.\n"); }
    if ( !$$self{gtype_confidence} ) { $self->throw("Missing the option gtype_confidence.\n"); }
    if ( !$$self{sample_dir} ) { $self->throw("Missing the option sample_dir.\n"); }

    return $self;
}


=head2 clean

        Description : If mrProper option is set, the entire QC directory will be deleted.
        Returntype  : None

=cut

sub clean
{
    my ($self) = @_;

    $self->SUPER::clean();

    if ( !$$self{'lane_path'} ) { $self->throw("Missing parameter: the lane to be cleaned.\n"); }
    if ( !$$self{'sample_dir'} ) { $self->throw("Missing parameter: the sample_dir to be cleaned.\n"); }

    if ( $$self{'mrProper'} ) 
    { 
        my $qc_dir = qq[$$self{'lane_path'}/$$self{'sample_dir'}];
        if ( ! -d $qc_dir ) { return; }

        $self->debug("rm -rf $qc_dir\n");
        Utils::CMD(qq[rm -rf $qc_dir]);
        return;
    }
}


=head2 lane_info

        Arg[1]      : field name: one of genotype,gtype_confidence
        Description : Temporary replacement of HierarchyUtilities::lane_info. Most of the data are now passed
                        to pipeline from a config file, including gender specific data. What's left are minor
                        things - basename of the lane and expected genotype name and confidence. Time will show
                        where to put this.
        Returntype  : field value

=cut

sub lane_info
{
    my ($self,$field) = @_;

    my $sample = $$self{sample};

    # By default, the genotype is named as sample. The exceptions should be listed
    #   in the known_gtypes hash.
    my $gtype = $sample;
    if ( exists($$self{known_gtypes}) &&  exists($$self{known_gtypes}{$sample}) )
    {
        $gtype = $$self{known_gtypes}{$sample};
    }
    if ( $field eq 'genotype' ) { return $gtype; }

    if ( $field eq 'gtype_confidence' )
    {
        if ( exists($$self{gtype_confidence}) && ref($$self{gtype_confidence}) eq 'HASH' )
        {
            if ( exists($$self{gtype_confidence}{$gtype}) ) { return $$self{gtype_confidence}{$gtype}; }
        }
        elsif ( exists($$self{gtype_confidence}) )
        {
            return $$self{gtype_confidence};
        }

        # If we are here, either there is no gtype_confidence field or it is a hash and does not
        #   contain the key $gtype. In such a case, return unrealisticly high value.
        return 1000;
    }

    $self->throw("Unknown field [$field] to lane_info\n");
}



#---------- rename_and_merge ---------------------

# Requires nothing
sub rename_and_merge_requires
{
    my ($self) = @_;
    my @requires = ();
    return \@requires;
}

sub rename_and_merge_provides
{
    my ($self) = @_;
    my @provides = ("$$self{sample_dir}/$$self{lane}.bam");
    return \@provides;
}

sub rename_and_merge
{
    my ($self,$lane_path,$lock_file) = @_;

    my $samtools = $$self{samtools};
    my $name     = $$self{lane};
    my @files    = glob("$lane_path/*.bam");
    if ( !scalar @files ) { $self->throw("No BAM files in [$lane_path]?"); }

    my $work_dir = "$lane_path/$$self{sample_dir}";
    Utils::create_dir("$work_dir");

    # This is a hack: The bam files produced by the mapping pipeline are named
    #   as MAPSTAT_ID.pe.raw.sorted.bam. In such a case, use the mapstat id to
    #   update the mapstats, so that the mapper and assembly information is preserved.
    #
    my %mapstat_ids;
    for my $file (@files)
    {
        if ( $file=~m{(\d+)\.[ps]e\.recal\.sorted\.bam} ) { push @{$mapstat_ids{$1}},$file; }
        elsif ( $file=~m{(\d+)\.[ps]e\.raw\.sorted\.bam} ) { push @{$mapstat_ids{$1}},$file; }
    }

    my @ids = sort { $b<=>$a } keys %mapstat_ids;
    if ( ! scalar @ids ) { $self->throw("No bam files in $lane_path?"); }

    # Take the bam file with the highest mapstat_id
    my $mapstat_id = $ids[0];

    # Remember the id for later
    open(my $fh,'>',"$work_dir/$$self{mapstat_id}") or $self->throw("$work_dir/$$self{mapstat_id}: $!");
    print $fh "$mapstat_id\n";
    close($fh);

    # There can be multiple files with this id, (paired and single end reads)
    @files = @{$mapstat_ids{$mapstat_id}};
    if ( scalar @files == 1 )
    {
        Utils::relative_symlink("$files[0]","$work_dir/$name.bam") unless -e "$work_dir/$name.bam";
        return $$self{'Yes'};
    }

    # If there are multiple bam files with the same mapstat_id, merge them
    my $bams = join(' ',@files);

    open($fh,'>', "$work_dir/_merge.pl") or Utils::error("$work_dir/_merge.pl: $!");
    print $fh qq[
use Utils;
Utils::CMD("$samtools merge x$name.bam $bams");
if ( ! -s "x$name.bam" ) { Utils::error("The command ended with an error:\\n\\t$samtools merge x$name.bam ../$bams\\n"); }
rename("x$name.bam","$name.bam") or Utils::error("rename x$name.bam $name.bam: \$!");
];
    close($fh);

    LSF::run($lock_file,$work_dir,"_${name}_merge",{bsub_opts=>$$self{bsub_opts_merge}}, q{perl -w _merge.pl});
    return $$self{'No'};
}



#----------- check_genotype ---------------------

sub check_genotype_requires
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my @requires = ("$sample_dir/$$self{lane}.bam");
    return \@requires;
}

sub check_genotype_provides
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my @provides = ("$sample_dir/$$self{lane}.gtype");
    return \@provides;
}

sub check_genotype
{
    my ($self,$lane_path,$lock_file) = @_;

    if ( !$$self{snps} ) { $self->throw("Missing the option snps.\n"); }

    my $name = $$self{lane};

    my $options = {};
    $$options{'bam'}           = "$lane_path/$$self{'sample_dir'}/$name.bam";
    $$options{'bsub_opts'}     = $$self{'bsub_opts'};
    $$options{'fa_ref'}        = $$self{'fa_ref'};
    $$options{'glf'}           = $$self{'glf'};
    $$options{'snps'}          = $$self{'snps'};
    $$options{'samtools'}      = exists($$self{samtools_glf}) ? $$self{samtools_glf} : $$self{'samtools'};
    $$options{'genotype'}      = $self->lane_info('genotype');
    $$options{'min_glf_ratio'} = $self->lane_info('gtype_confidence');
    $$options{'prefix'}        = $$self{'prefix'};
    $$options{'lock_file'}     = $lock_file;

    my $gtc = VertRes::Utils::GTypeCheck->new(%$options);
    $gtc->check_genotype();

    return $$self{'No'};
}


#----------- stats_and_graphs ---------------------

sub stats_and_graphs_requires
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my @requires = ("$sample_dir/$$self{lane}.bam");
    return \@requires;
}

sub stats_and_graphs_provides
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my @provides = ("$sample_dir/chrom-distrib.png","$sample_dir/gc-content.png","$sample_dir/gc-depth.png");
    return \@provides;
}

sub stats_and_graphs
{
    my ($self,$lane_path,$lock_file) = @_;

    my $sample_dir = $$self{'sample_dir'};
    my $lane  = $$self{lane};
    my $stats_ref = exists($$self{stats_ref}) ? $$self{stats_ref} : '';
    my $class = (caller(0))[0];  # In case we are called from a inherited object

    # Dynamic script to be run by LSF.
    open(my $fh, '>', "$lane_path/$sample_dir/_graphs.pl") or Utils::error("$lane_path/$sample_dir/_graphs.pl: $!");
    print $fh 
qq[
use VertRes::Pipelines::TrackQC_Bam;

my \%params = 
(
    'gc_depth_bin' => q[$$self{'gc_depth_bin'}],
    'mapviewdepth' => q[$$self{'mapviewdepth'}],
    'samtools'     => q[$$self{'samtools'}],
    'gcdepth_R'    => q[$$self{'gcdepth_R'}],
    'lane_path'    => q[$lane_path],
    'lane'         => q[$$self{lane}],
    'sample_dir'   => q[$$self{'sample_dir'}],
    'fa_ref'       => q[$$self{fa_ref}],
    'fai_ref'      => q[$$self{fai_ref}],
    'stats_ref'    => q[$stats_ref],
    'bwa_clip'     => q[$$self{bwa_clip}],
    'chr_regex'    => q[$$self{chr_regex}],
);

my \$qc = VertRes::Pipelines::TrackQC_Bam->new(\%params);
\$qc->run_graphs(\$params{lane_path});
];
    close $fh;

    LSF::run($lock_file,"$lane_path/$sample_dir","_${lane}_graphs", $self, qq{perl -w _graphs.pl});
    return $$self{'No'};
}


sub run_graphs
{
    my ($self,$lane_path) = @_;

    use Graphs;
    use SamTools;
    use Utils;

    # Set the variables
    my $sample_dir   = $$self{'sample_dir'};
    my $name         = $$self{lane};
    my $outdir       = "$lane_path/$sample_dir/";
    my $bam_file     = "$outdir/$name.bam";

    my $samtools     = $$self{'samtools'};
    my $mapview      = $$self{'mapviewdepth'};
    my $refseq       = $$self{'fa_ref'};
    my $fai_ref      = $$self{'fai_ref'};
    my $gc_depth_bin = $$self{'gc_depth_bin'};
    my $bindepth     = "$outdir/gc-depth.bindepth";
    my $gcdepth_R    = $$self{'gcdepth_R'};

    my $stats_file  = "$outdir/$$self{stats}";
    my $other_stats = "$outdir/$$self{stats_detailed}";
    my $dump_file   = "$outdir/$$self{stats_dump}";


    # The GC-depth graphs
    if ( ! -e "$outdir/gc-depth.png" || Utils::file_newer($bam_file,$bindepth) )
    {
        Utils::CMD("$samtools view $bam_file | $mapview $refseq -b=$gc_depth_bin > $bindepth");
        Graphs::create_gc_depth_graph($bindepth,$gcdepth_R,qq[$outdir/gc-depth.png]);
    }


    # Get stats from the BAM file
    my %opts = (do_clipped=>$$self{bwa_clip});
    if ( exists($$self{chr_regex}) ) { $opts{do_chrm} = $$self{chr_regex}; }
    my $all_stats = SamTools::collect_detailed_bam_stats($bam_file,$fai_ref,\%opts);
    my $stats = $$all_stats{'total'};
    report_detailed_stats($stats,$lane_path,$other_stats);
    dump_detailed_stats($stats,$dump_file);

    # Insert size graph
    my ($x,$y);
    if ( exists($$stats{insert_size}) )
    {
        $x = $$stats{'insert_size'}{'max'}{'x'};
        $y = $$stats{'insert_size'}{'max'}{'y'};

        # This is a very simple method of dynamic display range and will not work always. Should be done better if time allows.
        my $insert_size  = $$stats{insert_size}{main_bulk};
        Graphs::plot_stats({
                'outfile'    => qq[$outdir/insert-size.png],
                'title'      => 'Insert Size',
                'desc_yvals' => 'Frequency',
                'desc_xvals' => 'Insert Size',
                'data'       => [ $$stats{'insert_size'} ],
                'r_cmd'      => qq[text($x,$y,'$x',pos=4,col='darkgreen')\n],
                'r_plot'     => "xlim=c(0," . ($insert_size*1.5) . ")",
                });
    }

    # GC content graph
    $y = 0;
    my $normalize = 0; 
    my @gc_data   = ();
    if ( $$self{stats_ref} ) 
    {
        # Plot also the GC content of the reference sequence
        my ($gc_freqs,@xvals,@yvals);
        eval `cat $$self{stats_ref}`;
        if ( $@ ) { $self->throw($@); }

        for my $bin (sort {$a<=>$b} keys %$gc_freqs)
        {
            push @xvals,$bin;
            push @yvals,$$gc_freqs{$bin};
        }
        push @gc_data, { xvals=>\@xvals, yvals=>\@yvals, lines=>',lty=4', legend=>'ref' };
        $normalize = 1;
    }
    if ( $$stats{'gc_content_forward'} ) 
    {
        if ( $y < $$stats{'gc_content_forward'}{'max'}{'y'} )
        {
            $x = $$stats{'gc_content_forward'}{'max'}{'x'};
            $y = $$stats{'gc_content_forward'}{'max'}{'y'};
        }
        push @gc_data, { %{$$stats{'gc_content_forward'}}, legend=>'fwd' }; 
    }
    if ( $$stats{'gc_content_reverse'} ) 
    { 
        if ( $y < $$stats{'gc_content_reverse'}{'max'}{'y'} )
        {
            $x = $$stats{'gc_content_reverse'}{'max'}{'x'};
            $y = $$stats{'gc_content_reverse'}{'max'}{'y'};
        }
        push @gc_data, { %{$$stats{'gc_content_reverse'}}, legend=>'rev' }; 
    }
    if ( $$stats{'gc_content_single'} ) 
    { 
        if ( $y < $$stats{'gc_content_single'}{'max'}{'y'} )
        {
            $x = $$stats{'gc_content_single'}{'max'}{'x'};
            $y = $$stats{'gc_content_single'}{'max'}{'y'};
        }
        push @gc_data, { %{$$stats{'gc_content_single'}}, legend=>'single' }; 
    }
    if ( $normalize ) { $y=1; }
    Graphs::plot_stats({
            'outfile'    => qq[$outdir/gc-content.png],
            'title'      => 'GC Content (both mapped and unmapped)',
            'desc_yvals' => 'Frequency',
            'desc_xvals' => 'GC Content [%]',
            'data'       => \@gc_data,
            'r_cmd'      => sprintf("text($x,$y,'%.1f',pos=4,col='darkgreen')\n",$x),
            'normalize'  => $normalize,
            });

    # Chromosome distribution graph
    Graphs::plot_stats({
            'barplot'    => 1,
            'outfile'    => qq[$outdir/chrom-distrib.png],
            'title'      => 'Chromosome Coverage',
            'desc_yvals' => 'Frequency/Length',
            'desc_xvals' => 'Chromosome',
            'data'       => [ $$stats{'reads_chrm_distrib'}, ],
            });
}



sub report_detailed_stats
{
    my ($stats,$lane_path,$outfile) = @_;

    open(my $fh,'>',$outfile) or Utils::error("$outfile: $!");

    printf $fh "reads total .. %d\n", $$stats{'reads_total'};
    printf $fh "     mapped .. %d (%.1f%%)\n", $$stats{'reads_mapped'}, 100*($$stats{'reads_mapped'}/$$stats{'reads_total'});
    printf $fh "     paired .. %d (%.1f%%)\n", $$stats{'reads_paired'}, 100*($$stats{'reads_paired'}/$$stats{'reads_total'});
    printf $fh "bases total .. %d\n", $$stats{'bases_total'};
    printf $fh "    clip bases     .. %d (%.1f%%)\n", $$stats{'clip_bases'}, 100*($$stats{'clip_bases'}/$$stats{'bases_total'});
    printf $fh "    mapped (read)  .. %d (%.1f%%)\n", $$stats{'bases_mapped_read'}, 100*($$stats{'bases_mapped_read'}/$$stats{'clip_bases'});
    printf $fh "    mapped (cigar) .. %d (%.1f%%)\n", $$stats{'bases_mapped_cigar'}, 100*($$stats{'bases_mapped_cigar'}/$$stats{'clip_bases'});
    printf $fh "error rate  .. %f\n", $$stats{error_rate};
    printf $fh "rmdup\n";
    printf $fh "     reads total  .. %d (%.1f%%)\n", $$stats{'rmdup_reads_total'}, 100*($$stats{'rmdup_reads_total'}/$$stats{'reads_total'});
    printf $fh "     reads mapped .. %d (%.1f%%)\n", $$stats{'rmdup_reads_mapped'}, 100*($$stats{'rmdup_reads_mapped'}/$$stats{'rmdup_reads_total'});
    printf $fh "     bases mapped (cigar) .. %d (%.1f%%)\n", $$stats{'rmdup_bases_mapped_cigar'}, 
           100*($$stats{'rmdup_bases_mapped_cigar'}/$$stats{'rmdup_bases_total'});
    printf $fh "duplication .. %f\n", $$stats{'duplication'};
    printf $fh "\n";
    printf $fh "insert size        \n";
    if ( exists($$stats{insert_size}) )
    {
        printf $fh "    average .. %.1f\n", $$stats{insert_size}{average};
        printf $fh "    std dev .. %.1f\n", $$stats{insert_size}{std_dev};
    }
    else
    {
        printf $fh "    N/A\n";
    }
    printf $fh "\n";
    printf $fh "chrm distrib dev .. %f\n", $$stats{'reads_chrm_distrib'}{'scaled_dev'};

    close $fh;
}


sub dump_detailed_stats
{
    my ($stats,$outfile) = @_;

    use Data::Dumper;
    open(my $fh,'>',$outfile) or Utils::error("$outfile: $!");
    print $fh Dumper($stats);
    close $fh;
}


#----------- auto_qc ---------------------

sub auto_qc_requires
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my $name = $$self{lane};
    my @requires = ("$sample_dir/gc-content.png","$sample_dir/${name}.gtype","$sample_dir/$$self{stats_dump}");
    return \@requires;
}

# See description of update_db.
#
sub auto_qc_provides
{
    my ($self) = @_;

    if ( exists($$self{db}) ) { return 0; }

    my @provides = ();
    return \@provides;
}

sub auto_qc
{
    my ($self,$lane_path,$lock_file) = @_;

    my $sample_dir = "$lane_path/$$self{sample_dir}";
    if ( !$$self{db} ) { $self->throw("Expected the db key.\n"); }

    my $vrtrack   = VRTrack::VRTrack->new($$self{db}) or $self->throw("Could not connect to the database: ",join(',',%{$$self{db}}),"\n");
    my $name      = $$self{lane};
    my $vrlane    = VRTrack::Lane->new_by_hierarchy_name($vrtrack,$name) or $self->throw("No such lane in the DB: [$name]\n");

    if ( !$vrlane->is_processed('import') ) { return $$self{Yes}; }

    # Get the stats dump
    my $stats = do "$sample_dir/$$self{stats_dump}";
    if ( !$stats ) { $self->throw("Could not read $sample_dir/$$self{stats_dump}\n"); }

    my @qc_status = ();
    my ($test,$status,$reason);

    # Genotype check results
    if ( exists($$self{auto_qc}{gtype_regex}) )
    {
        my $gtype  = VertRes::Utils::GTypeCheck::get_status("$sample_dir/${name}.gtype");
        $test   = 'Genotype check';
        $status = 1;
        $reason = qq[The status is '$$gtype{status}'.];
        if ( !($$gtype{status}=~$$self{auto_qc}{gtype_regex}) ) 
        { 
            $status=0; 
            $reason="The status ($$gtype{status}) does not match the regex ($$self{auto_qc}{gtype_regex})."; 
        }
        push @qc_status, { test=>$test, status=>$status, reason=>$reason };
    }

    # Mapped bases
    if ( exists($$self{auto_qc}{mapped_bases}) )
    {
        my $min = $$self{auto_qc}{mapped_bases};
        $test   = 'Mapped bases';
        $status = 1;
        my $value = 100.*$$stats{'bases_mapped_cigar'}/$$stats{'clip_bases'};
        $reason = "At least $min% bases mapped after clipping ($value%).";
        if ( $value < $min ) { $status=0; $reason="Less than $min% bases mapped after clipping ($value%)."; }
        push @qc_status, { test=>$test, status=>$status, reason=>$reason };
    }

    # Error rate
    if ( exists($$self{auto_qc}{error_rate}) )
    {
        my $min = $$self{auto_qc}{error_rate};
        $test   = 'Error rate';
        $status = 1;
        $reason = "The error rate smaller than $min ($$stats{error_rate}).";
        if ( $$stats{error_rate} > $min ) { $status=0; $reason="The error rate higher than $min ($$stats{error_rate})."; }
        push @qc_status, { test=>$test, status=>$status, reason=>$reason };
    }

    $vrtrack->transaction_start();

    # Insert size. 
    if ( $vrlane->is_paired() && exists($$self{auto_qc}{inserts_peak_win}) && exists($$self{auto_qc}{inserts_within_peak}) )
    {
        $test = 'Insert size';
        if ( !exists($$stats{insert_size}) ) 
        { 
            push @qc_status, { test=>$test, status=>0, reason=>'The insert size not available, yet flagged as paired' };
        }
        else
        {
            # Only libraries can be failed based on wrong insert size. The lanes are always passed as
            #   long as the insert size is consistent with other lanes from the same library.

            my $peak_win    = $$self{auto_qc}{inserts_peak_win};
            my $within_peak = $$self{auto_qc}{inserts_within_peak};

            $status = 1;
            my ($amount,$range) = insert_size_ok($$stats{insert_size}{xvals},$$stats{insert_size}{yvals},$peak_win,$within_peak);
            $reason = "There are $within_peak% or more inserts within $peak_win% of max peak ($amount).";
            if ( $amount<$within_peak ) 
            { 
                $status=0; $reason="Fail library, less than $within_peak% of the inserts are within $peak_win% of max peak ($amount)."; 
            }
            push @qc_status, { test=>$test, status=>1, reason=>$reason };

            $reason = "$within_peak% of inserts are contained within $peak_win% of the max peak ($range).";
            if ( $range>$peak_win )
            {
                $status=0; $reason="Fail library, $within_peak% of inserts are not within $peak_win% of the max peak ($range).";
            }
            push @qc_status, { test=>'Insert size (rev)', status=>1, reason=>$reason };

            my $vrlib = VRTrack::Library->new_by_field_value($vrtrack,'library_id',$vrlane->library_id()) or $self->throw("No vrtrack library?");
            $vrlib->auto_qc_status($status ? 'passed' : 'failed');
            $vrlib->update();
        }
    }


    # Now output the results.
    open(my $fh,'>',"$sample_dir/auto_qc.txt") or $self->throw("$sample_dir/auto_qc.txt: $!");
    $status = 1;
    for my $stat (@qc_status)
    {
        if ( !$$stat{status} ) { $status=0; }
        print $fh "$$stat{test}:\t", ($$stat{status} ? 'PASSED' : 'FAILED'), "\t # $$stat{reason}\n";
    }
    print $fh "Verdict:\t", ($status ? 'PASSED' : 'FAILED'), "\n";
    close($fh);

    # Then write to the database.
    $vrlane->auto_qc_status($status ? 'passed' : 'failed');
    $vrlane->update();
    $vrtrack->transaction_commit();

    return $$self{'Yes'};
}


# xvals, yvals, calculates 
#   1) what percentage of the data lies within the allowed range from the max peak (e.g. [mpeak*(1-0.25),mpeak*(1+0.25)])
#   2) how wide is the distribution - how wide has to be the range to accomodate the given amount of data (e.g. 80% of the reads) 
sub insert_size_ok
{
    my ($xvals,$yvals,$maxpeak_range,$data_amount) = @_;

    # Determine the max peak
    my $count     = 0;
    my $imaxpeak  = 0;
    my $ndata     = scalar @$xvals;
    my $total_count = 0;
    my $max = 0;
    for (my $i=0; $i<$ndata; $i++)
    {
        my $xval = $$xvals[$i];
        my $yval = $$yvals[$i];

        $total_count += $yval;
        if ( $max < $yval ) { $imaxpeak = $i; $max = $yval; }
    }

    # See how many reads are within the median range (really the median? looks more like the max peak!)
    $maxpeak_range *= 0.01;
    $count = 0;
    for (my $i=0; $i<$ndata; $i++)
    {
        my $xval = $$xvals[$i];
        my $yval = $$yvals[$i];

        if ( $xval<$$xvals[$imaxpeak]*(1-$maxpeak_range) ) { next; }
        if ( $xval>$$xvals[$imaxpeak]*(1+$maxpeak_range) ) { next; }
        $count += $yval;
    }
    my $out_amount = 100.0*$count/$total_count;

    # How big must be the range in order to accomodate the requested amount of data
    $data_amount *= 0.01;
    my $idiff = 0;
    $count = $$yvals[$imaxpeak];
    while ( $count/$total_count < $data_amount )
    {
        $idiff++;
        if ( $idiff<=$imaxpeak ) { $count += $$yvals[$imaxpeak-$idiff]; }
        if ( $idiff+$imaxpeak<$ndata ) { $count += $$yvals[$imaxpeak+$idiff]; }

        # This should never happen, unless $data_range is bigger than 100%
        if ( $idiff>$imaxpeak && $idiff+$imaxpeak>=$ndata ) { last; }
    }
    my $out_range  = $idiff<=$imaxpeak ? $$xvals[$imaxpeak]-$$xvals[$imaxpeak-$idiff] : $$xvals[$imaxpeak];
    my $out_range2 = $idiff+$imaxpeak<$ndata ? $$xvals[$imaxpeak+$idiff]-$$xvals[$imaxpeak] : $$xvals[-1]-$$xvals[$imaxpeak];
    if ( $out_range2 > $out_range ) { $out_range=$out_range2; }
    $out_range = 100.0*$out_range/$$xvals[$imaxpeak];

    return ($out_amount,$out_range);
}


#----------- update_db ---------------------

sub update_db_requires
{
    my ($self) = @_;
    my $sample_dir = $$self{'sample_dir'};
    my $name = $$self{lane};
    my @requires = ("$sample_dir/chrom-distrib.png","$sample_dir/gc-content.png",
        "$sample_dir/gc-depth.png","$sample_dir/${name}.gtype","$sample_dir/$$self{stats_dump}");
    return \@requires;
}

# This subroutine will check existence of the key 'db'. If present, it is assumed
#   that QC should write the stats and status into the VRTrack database. In this
#   case, 0 is returned, meaning that the task must be run. The task will change the
#   QC status from 'no_qc' to something else, therefore we will not be called again.
#
#   If the key 'db' is absent, the empty list is returned and the database will not
#   be written.
#
sub update_db_provides
{
    my ($self) = @_;

    if ( exists($$self{db}) ) { return 0; }

    my @provides = ();
    return \@provides;
}

sub update_db
{
    my ($self,$lane_path,$lock_file) = @_;

    my $sample_dir = "$lane_path/$$self{sample_dir}";
    if ( !$$self{db} ) { $self->throw("Expected the db key.\n"); }

    # First check if the 'no_qc' status is still present. Another running pipeline
    #   could have queued the job a long time ago and the stats might have been
    #   already written.
    my $vrtrack   = VRTrack::VRTrack->new($$self{db}) or $self->throw("Could not connect to the database: ",join(',',%{$$self{db}}),"\n");
    my $name      = $$self{lane};
    my $vrlane    = VRTrack::Lane->new_by_hierarchy_name($vrtrack,$name) or $self->throw("No such lane in the DB: [$name]\n");

    if ( !$vrlane->is_processed('import') ) { return $$self{Yes}; }

    # Get the stats dump
    my $stats = do "$sample_dir/$$self{stats_dump}";
    if ( !$stats ) { $self->throw("Could not read $sample_dir/$$self{stats_dump}\n"); }

    my $read_length = $$stats{bases_total} / $$stats{reads_total};

    my $gtype = VertRes::Utils::GTypeCheck::get_status("$sample_dir/${name}.gtype");

    my %images = ();
    if ( -e "$sample_dir/chrom-distrib.png" ) { $images{'chrom-distrib.png'} = 'Chromosome Coverage'; }
    if ( -e "$sample_dir/gc-content.png" ) { $images{'gc-content.png'} = 'GC Content'; }
    if ( -e "$sample_dir/insert-size.png" ) { $images{'insert-size.png'} = 'Insert Size'; }
    if ( -e "$sample_dir/gc-depth.png" ) { $images{'gc-depth.png'} = 'GC Depth'; }
    if ( -e "$sample_dir/fastqcheck_1.png" ) { $images{'fastqcheck_1.png'} = 'FastQ Check 1'; }
    if ( -e "$sample_dir/fastqcheck_2.png" ) { $images{'fastqcheck_2.png'} = 'FastQ Check 2'; }
    if ( -e "$sample_dir/fastqcheck.png" ) { $images{'fastqcheck.png'} = 'FastQ Check'; }

    my $nadapters = 0;
    if ( -e "$sample_dir/${name}_1.nadapters" ) { $nadapters += do "$sample_dir/${name}_1.nadapters"; }
    if ( -e "$sample_dir/${name}_2.nadapters" ) { $nadapters += do "$sample_dir/${name}_1.nadapters"; }

    $vrtrack->transaction_start();

    # Now call the database API and fill the mapstats object with values
    my $mapping;
    my $has_mapstats = 0;

    if ( -e "$sample_dir/$$self{mapstat_id}" )
    {
        # When run on bam files created by the mapping pipeline, reuse existing
        #   mapstats, so that the mapper and assembly information is not overwritten.
        my ($mapstats_id) = `cat $sample_dir/$$self{mapstat_id}`;
        chomp($mapstats_id);
        $mapping = VRTrack::Mapstats->new($vrtrack, $mapstats_id);
        if ( $mapping ) { $has_mapstats=1; }
    }
    if ( !$mapping ) { $mapping = $vrlane->add_mapping(); }

    # Fill the values in
    $mapping->raw_reads($$stats{reads_total});
    $mapping->raw_bases($$stats{bases_total});
    $mapping->reads_mapped($$stats{reads_mapped});
    $mapping->reads_paired($$stats{reads_paired});
    $mapping->bases_mapped($$stats{bases_mapped_cigar});
    $mapping->error_rate($$stats{error_rate});
    $mapping->rmdup_reads_mapped($$stats{rmdup_reads_mapped});
    $mapping->rmdup_bases_mapped($$stats{rmdup_bases_mapped_cigar});
    $mapping->adapter_reads($nadapters);
    $mapping->clip_bases($$stats{clip_bases});

    $mapping->mean_insert($$stats{insert_size}{average});
    $mapping->sd_insert($$stats{insert_size}{std_dev});

    $mapping->genotype_expected($$gtype{expected});
    $mapping->genotype_found($$gtype{found});
    $mapping->genotype_ratio($$gtype{ratio});
    $vrlane->genotype_status($$gtype{status});

    if ( !$has_mapstats )
    {
        if ( !$$self{assembly} ) { $self->throw("Expected the assembly key.\n"); }
        if ( !$$self{mapper} ) { $self->throw("Expected the mapper key.\n"); }
        if ( !$$self{mapper_version} ) { $self->throw("Expected the mapper_version key.\n"); }

        my $assembly = $mapping->assembly($$self{assembly});
        if (!$assembly) { $assembly = $mapping->add_assembly($$self{assembly}); }

        my $mapper = $mapping->mapper($$self{mapper},$$self{mapper_version});
        if (!$mapper) { $mapper = $mapping->add_mapper($$self{mapper},$$self{mapper_version}); }
    }

    # Do the images
    while (my ($imgname,$caption) = each %images)
    {
        my $img = $mapping->add_image_by_filename("$sample_dir/$imgname");
        $img->caption($caption);
        $img->update;
    }

    # Write the QC status. Never overwrite a QC status set previously by human. Only NULL or no_qc can be overwritten.
    $mapping->update;
    $vrlane->is_processed('qc',1);
    my $qc_status = $vrlane->qc_status();
    if ( !$qc_status || $qc_status eq 'no_qc' ) { $vrlane->qc_status('pending'); } # Never change status which was set manually
    $vrlane->update;

    my $vrlibrary = VRTrack::Library->new($vrtrack,$vrlane->library_id()) or $self->throw("No such library in the DB: lane=[$name]\n");
    $qc_status = $vrlibrary->qc_status();
    if ( !$qc_status || $qc_status eq 'no_qc' ) 
    { 
        $vrlibrary->qc_status('pending'); 
        $vrlibrary->update(); 
    }
    $vrtrack->transaction_commit();

    # Clean the big files
    for my $file ('gc-depth.bindepth',"$$self{lane}.bam.bai","$$self{lane}*.sai","$$self{lane}*.fastq.gz","$$self{lane}.bam","$$self{lane}.glf")
    {
        Utils::CMD("rm -f $sample_dir/$file");
    }

    if ( $$self{clean_fastqs} )
    {
        Utils::CMD("rm -f $lane_path/$$self{lane}*.fastq.gz");
    }

    return $$self{'Yes'};
}


#---------- Debugging and error reporting -----------------

sub format_msg
{
    my ($self,@msg) = @_;
    return '['. scalar gmtime() ."]\t". join('',@msg);
}

sub warn
{
    my ($self,@msg) = @_;
    my $msg = $self->format_msg(@msg);
    if ($self->verbose > 0) 
    {
        print STDERR $msg;
    }
    $self->log($msg);
}

sub debug
{
    # The granularity of verbose messaging does not make much sense
    #   now, because verbose cannot be bigger than 1 (made Base.pm
    #   throw on warn's).
    my ($self,@msg) = @_;
    if ($self->verbose > 0) 
    {
        my $msg = $self->format_msg(@msg);
        print STDERR $msg;
        $self->log($msg);
    }
}

sub throw
{
    my ($self,@msg) = @_;
    my $msg = $self->format_msg(@msg);
    Utils::error($msg);
}

sub log
{
    my ($self,@msg) = @_;

    my $msg = $self->format_msg(@msg);
    my $status  = open(my $fh,'>>',$self->log_file);
    if ( !$status ) 
    {
        print STDERR $msg;
    }
    else 
    { 
        print $fh $msg; 
    }
    if ( $fh ) { close($fh); }
}


1;

