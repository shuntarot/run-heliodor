# Directives for synthesis on the VCU118. With the default ones the design
# does not route: too many signals in too small an area.
set SYNTH_DIRECTIVE    AlternateRoutability
set OPT_DIRECTIVE      Explore
set PLACE_DIRECTIVE    SSI_SpreadLogic_high
set PHYS_OPT_DIRECTIVE AggressiveExplore
set ROUTE_DIRECTIVE    AlternateCLBRouting
