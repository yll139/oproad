set_global_routing_layer_adjustment MINT1-MINT2 0.5
set_global_routing_layer_adjustment MINT3-$::env(MAX_ROUTING_LAYER) 0.25

set_routing_layers -signal $::env(MIN_ROUTING_LAYER)-$::env(MAX_ROUTING_LAYER)
