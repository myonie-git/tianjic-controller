// File        : tj_case_select.svh
// Description : Optional scene selection for simulation testbenches.
// Include inside a testbench module. Empty selection keeps the default sequence.
string tj_case_ids[$];
bit tj_case_filter_active = 0;

function automatic bit tj_case_list_has(input string list, input string id);
  string token;
  token = "";
  for (int i = 0; i <= list.len(); i++) begin
    if (i == list.len() || list.getc(i) == 44 || list.getc(i) == 32 ||
        list.getc(i) == 9) begin
      if (token == id) return 1;
      token = "";
    end else token = {token, list.getc(i)};
  end
  return 0;
endfunction

task automatic tj_cases_init(input string available);
  string requested, token;
  if (!$value$plusargs("TJ_CASES=%s", requested) || requested.len() == 0) return;
  tj_case_filter_active = 1;
  token = "";
  for (int i = 0; i <= requested.len(); i++) begin
    if (i == requested.len() || requested.getc(i) == 44 || requested.getc(i) == 32 ||
        requested.getc(i) == 9) begin
      if (token.len() != 0) begin
        if (!tj_case_list_has(available, token))
          $fatal(1, "Unknown case %s; available: %s", token, available);
        tj_case_ids.push_back(token);
      end
      token = "";
    end else token = {token, requested.getc(i)};
  end
  if (tj_case_ids.size() == 0) tj_case_filter_active = 0;
  $display("CASE SELECTION: %s", requested);
endtask

function automatic bit tj_case_wanted(input string id);
  if (!tj_case_filter_active) return 1;
  foreach (tj_case_ids[i]) if (tj_case_ids[i] == id) return 1;
  return 0;
endfunction

function automatic bit tj_run_case(input string id);
  bit selected;
  selected = tj_case_wanted(id);
  if (selected) $display("CASE RUN %s", id);
  else          $display("CASE SKIP %s", id);
  return selected;
endfunction
