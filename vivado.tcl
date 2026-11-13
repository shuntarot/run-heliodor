# Directives for synthesis. With the default ones the design does not route
# on the VCU118: too many signals in too small an area. The fp1, with four
# harts across its three SLRs, takes the same ones.
set SYNTH_DIRECTIVE    AlternateRoutability
set OPT_DIRECTIVE      Explore
set PLACE_DIRECTIVE    SSI_SpreadLogic_high
set PHYS_OPT_DIRECTIVE AggressiveExplore
set ROUTE_DIRECTIVE    AlternateCLBRouting
