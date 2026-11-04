// UVM sequence types required by soc_base_test in the 4x1 Controller flow.
// The Controller testbench supplies all stimulus.
class make_HEX_sequence extends uvm_sequence;
    `uvm_object_utils(make_HEX_sequence)
    function new(string name = "make_HEX_sequence");
        super.new(name);
    endfunction
    virtual task body();
    endtask
endclass

class wait_for_HEX_done_sequence extends uvm_sequence;
    `uvm_object_utils(wait_for_HEX_done_sequence)
    function new(string name = "wait_for_HEX_done_sequence");
        super.new(name);
    endfunction
    virtual task body();
    endtask
endclass
