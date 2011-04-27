
=head1 NAME

Bio::SecreTary::TMpred_Cinline

=head1 DESCRIPTION

An object to run the trans-membrane helix prediction program tmpred.

=head1 AUTHOR

Tom York (tly2@cornell.edu)

=cut

package Bio::SecreTary::TMpred_Cinline;
use base qw / Bio::SecreTary::TMpred /;
use List::Util qw / min max /;

use Inline C => <<'END_C';

double max_index_in_range( SV * terms, int start, int stop ) {
        I32 numterms = 0;
        /* Make sure we have an array ref with values */
        if ((!SvROK(terms))
                        || (SvTYPE(SvRV(terms)) != SVt_PVAV)
                        || ((numterms = av_len((AV *)SvRV(terms))) < 0)) {
                return -10000;
        }
        /* Set result to first value in array */
        if(start < 0) { start = 0; }
        if(stop > numterms){ stop = numterms; }
        double max = SvNV(* av_fetch((AV *)SvRV(terms), start, 0));
        long max_index = start;
        long i;
        for (i = start+1; i <= stop; i++) {
                double thisval = SvNV(* av_fetch((AV *)SvRV(terms), i, 0));
                if(thisval > max){
                        max = thisval;
                        max_index = i;
                }
        }
       return max_index;
}

double max_in_range( SV * terms, int start, int stop ) {
        I32 numterms = 0;
        /* Make sure we have an array ref with values */
        if ((!SvROK(terms))
                        || (SvTYPE(SvRV(terms)) != SVt_PVAV)
                        || ((numterms = av_len((AV *)SvRV(terms))) < 0)) {
                return -10000;
        }
        /* Set result to first value in array */
        if(start < 0) { start = 0; }
        if(stop > numterms){ stop = numterms; }
        double max = SvNV(* av_fetch((AV *)SvRV(terms), start, 0));
        long i;
        for (i = start+1; i <= stop; i++) {
                double thisval = SvNV(* av_fetch((AV *)SvRV(terms), i, 0));
                if(thisval > max){
                        max = thisval;
                }
        }
       return max;
}




END_C

use Readonly;
Readonly my $FALSE    => 0;
Readonly my $TRUE     => 1;
Readonly my %defaults => (

			  #  'version'                     => 'perl',
			  'min_score'                   => 500,
			  'min_tm_length'               => 17,
			  'max_tm_length'               => 33,
			  'min_beg'                     => 0,
			  'max_beg'                     => 35,
			  'lo_orientational_threshold'  => 80,
			  'hi_orientational_threshold'  => 200,
			  'avg_orientational_threshold' => 80
			 );

Readonly my $IMITATE_PASCAL_CODE =>
  $TRUE;      # if this is true, does the same as the old pascal code.
Readonly my $TMHLOFFSET => ($IMITATE_PASCAL_CODE)
  ? 1
  : 0;

# TMHLOFFSET gets added to the max_tmh_length,
# and (1 - TMHLOFFSET) gets subtracted from min_tmh_length
# TMHLOFFSET => 1  makes it agree with pascal code.
# finds helices with length as large as next bigger odd number, e.g. if
# $max_tmh_length is 33, will find some helices of lengths 34 and 35.
# with TMHLOFFSET => 0, 33->33, 32->33, 31->31, etc. i.e. goes up to
# next greater OR EQUAL odd number, rather than to next STRICTLY greater odd.
# similarly the min length is affected. with TMHLOFFSET => 1, 17->17, 16->17, 15->15
# i.e. if you specify min length of 16 you will never see helices shorter than 17
# but with TMHLOFFSET => 0, 17->17, 16->15, 15->15, etc. now you find
# the length 16 ones, (as well as length 15 ones which are discarded in good_solutions).
# set up defaults for tmpred parameters:

=head2 function new

  Synopsis : my $tmpred_obj = Bio::SecreTary::TMpred->new();    # using defaults
  or my $tmpred_obj = Bio::SecreTary::TMpred->new( { min_score => 600 } );
  Arguments: $arg_hash_ref holds some parameters describing which 
      solutions will be found by tmpred :
      min_score, min_tm_length, max_tm_length, min_beg, max_beg . 
  Returns: an instance of a TMpred object 
  Side effects: Creates the object . 
  Description: Creates a TMpred object with certain parameters which 
      determine which trans-membrane helices to find.

=cut

sub new {
  my $class        = shift;
  my $self  = $class->SUPER::new(@_); #         = bless {}, $class;
  return $self;
}

sub make_profile {		    # makes a profile, i.e. an array
				    # containing ...
				    # my $sequence     = shift;
  my $seq_aanumber_array = shift;   # ref to array of numbers
  my $table              = shift;
  my $ref_position       = $table->marked_position();
  my $matrix             = $table->table();
  my $ncols   = scalar @{ $matrix->[0] }; # ncols is # elements in first row
  my @profile = ();
  my $length = scalar @$seq_aanumber_array; #length $sequence;

  # need to be careful here to make it consistent with pascal code,
  # which has 1-based arrays. ref_position is 1 less than in pascal code for this reason.
  for ( my $k = 0 ; $k < $length ; $k++ ) {
    my $m    = 0;
    my $kmrf = $k - $ref_position;
    my $plo  = max($kmrf, 0);		# $kmrf = $k - $ref_position;
   # $plo = 0 if ( $plo < 0 );
    my $pup = min($ncols + $kmrf, $length);
  #  $pup = $length if ( $pup > $length );

    for ( my ( $p, $i ) = ( $plo, $plo - $kmrf ) ; $p < $pup ; $p++, $i++ ) {
      $m += $matrix->[ $seq_aanumber_array->[$p] ]->[$i];
    }

    my $round_m =
      ( $m < 0 ) ? int( $m * 100 - 0.5 ) : int( $m * 100 + 0.5 );
    push @profile, $round_m;
  }

  return \@profile;
}

sub make_curve {
  my $self      = shift;
  my $m_profile = shift;
  my $n_profile = shift;
  my $c_profile = shift;
  my $min_halfw =
    $self->{min_halfw};	# int( ( (shift) - ( 1 - $TMHLOFFSET ) ) / 2 );
  my $max_halfw = $self->{max_halfw}; # int( ( (shift) + $TMHLOFFSET ) / 2 );
  my $length    = scalar @$m_profile;
  my @score;

  # have to be careful here going to 0-based index $i
  for ( my $i = 0 ; $i < $length ; $i++ ) {
    if (   ( $i + 1 <= $min_halfw )
	   or ( $i + 1 > ( $length - $min_halfw ) ) ) {
      $score[$i] = 0;
    } else {
      my $n_start = ( $i - $max_halfw > 0 ) ? $i - $max_halfw : 0;
      my $c_end =
	( $i + $max_halfw < $length ) ? $i + $max_halfw : $length - 1;

      my $s1 = max_in_range($n_profile, $n_start, $i - $min_halfw);
      my $s2 = max_in_range($c_profile, $i + $min_halfw, $c_end); 


 $score[$i] = $m_profile->[$i] + $s1 + $s2;
    }
  }
  return \@score;
}

sub find_helix {
  my $self = shift;
  my ( $length, $start, $s, $m, $n, $c ) = @_;

  # $s, $m, $n, $c are refs to arrays
  # $io_score, $io_center_prof, $io_nterm_prof, $io_cterm_prof
  # or $oi_score, $oi_center_prof, ...
  my $min_halfw = $self->{min_halfw};
  my $max_halfw = $self->{max_halfw};
  my $helix; #     = Bio::SecreTary::Helix->new();

  my $find_helix_result;

  my ( $found, $done );
  my $i = max($start, $min_halfw);

  $found = $FALSE;

  while ( ( $i < $length - $min_halfw ) and ( !$found ) ) {

     # my $pos = max_index_in_range( $s, $i - $min_halfw, $i + $max_halfw );
     # my $scr = $s->[$pos];
      my $scr = max_in_range( $s, $i - $min_halfw, $i + $max_halfw );

    if ( ( $s->[$i] == $scr ) and ( $s->[$i] > 0 ) ) {
      $found = $TRUE;
      $helix = Bio::SecreTary::Helix->new();

      $helix->center( [ $i, $m->[$i] ] );
      my $beg = max($i - $max_halfw, 0);

      my $nt_position = max_index_in_range( $n, $beg, $i - $min_halfw );
      my $nt_score = $n->[$nt_position];

      $helix->nterm( [ $nt_position, $nt_score ] );

      my $end = $i + $max_halfw;
      $end = $length - 1 if ( $end >= $length );

      my $ct_position = max_index_in_range( $c, $i + $min_halfw, $end );
      my $ct_score = $c->[$ct_position];

      $helix->cterm( [ $ct_position, $ct_score ] );

      my $j = $i - $min_halfw;	# determine nearest N-terminus
      $done = $FALSE;
      while (
	     $j - 1 >= 0	#  0 not 1 because 0-based
	     and $j - 1 >= $i - $max_halfw and !$done
	    ) {
	if ( $n->[ $j - 1 ] > $n->[$j] ) {
	  $j--;
	} else {
	  $done = $TRUE;
	}
      }

      $helix->sh_nterm( [ $j, $n->[$j] ] );

      $j    = $i + $min_halfw;
      $done = $FALSE;
      while ( $j + 1 < $length
	      and $j + 1 <= $i + $max_halfw
	      and !$done ) {
	if ( defined $c->[ $j + 1 ] and defined $c->[$j] ) {
	  if ( $c->[ $j + 1 ] > $c->[$j] ) {
	    $j++;
	  } else {
	    $done = $TRUE;
	  }
	} else {
	  print "j, c[j], c[j+1]: ", $j, " ", $c->[$j], " ",
	    $c->[ $j + 1 ], " ", $length, "\n";
	  exit;
	}
      }

      $helix->sh_cterm( [ $j, $c->[$j] ] );
    }	   # end of if helix found block
    $i++;
  }	   # end of while loop
  if ($found) {
    $start = $helix->sh_cterm()->[0] + 1;

    my $the_score =
      $helix->center()->[1] + $helix->nterm()->[1] + $helix->cterm()->[1];
    $helix->score($the_score);
    $find_helix_result = $TRUE;
  } else {
    $start             = $length;
    $find_helix_result = $FALSE;
  }

  return ( $find_helix_result, $start, $helix );
}				# end of sub find_helix

1;
