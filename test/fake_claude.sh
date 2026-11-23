#!/usr/bin/env bash
# Stand-in for the `claude` CLI used by the tests. Emits canned stream-json.
log="${FAKE_CLAUDE_LOG:-/dev/null}"
printf '%s\n' "ARGS $*" >> "$log"
printf '%s\n' "CWD $PWD" >> "$log"
sid="11111111-2222-3333-4444-555555555555"

if [[ " $* " != *" --input-format "* ]]; then
  # One-shot inline edit: prompt on stdin, JSON result on stdout.
  prompt=$(cat)
  printf '%s\n' "PROMPT $prompt" >> "$log"
  if [[ "$prompt" == *"Instruction: FAIL"* ]]; then
    echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}'
  else
    echo '{"type":"result","subtype":"success","is_error":false,"result":"```\nlet x = 42\nlet y = 43\n```"}'
  fi
  exit 0
fi

echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\",\"model\":\"fake-model\",\"slash_commands\":[\"hi\",\"clear\",\"compact\",\"cost\",\"model\",\"__internal\"]}"
se() { echo "{\"type\":\"stream_event\",\"parent_tool_use_id\":null,\"event\":$1}"; }
nmsg=0
while IFS= read -r line; do
  if [[ "$line" == *'"type":"control_request"'* ]]; then
    # Control requests sent while idle: log and acknowledge like the real CLI.
    printf '%s\n' "CTRL $line" >> "$log"
    rid=$(sed -n 's/.*"request_id":"\([^"]*\)".*/\1/p' <<<"$line")
    if [[ "$line" == *'"rewind_files"'* ]]; then
      if [[ "$line" == *nocheckpoint* ]]; then
        echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$rid\",\"response\":{\"canRewind\":false,\"error\":\"No file checkpoint found\"}}}"
      elif [[ "$line" == *'"dry_run":true'* ]]; then
        echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$rid\",\"response\":{\"canRewind\":true,\"filesChanged\":[\"$PWD/a.txt\",\"$PWD/sub/b.txt\"],\"insertions\":1,\"deletions\":2}}}"
      else
        echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$rid\",\"response\":{\"canRewind\":true,\"skippedLinks\":0}}}"
      fi
    elif [[ "$line" == *'"set_model"'* ]]; then
      m=$(sed -n 's/.*"model":"\([^"]*\)".*/\1/p' <<<"$line")
      echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$rid\",\"response\":{\"model\":\"claude-${m:-default}\"}}}"
    elif [[ "$line" == *'FAILMODE'* ]]; then
      echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"error\",\"request_id\":\"$rid\",\"error\":\"nope\"}}"
    else
      echo "{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"$rid\",\"response\":{}}}"
    fi
    continue
  fi
  printf '%s\n' "STDIN $line" >> "$log"
  if [[ " $* " == *" --replay-user-messages "* && "$line" == *'"role":"user"'* ]]; then
    # Like the real CLI: echo each user message back, numbered.
    nmsg=$((nmsg + 1))
    c=$(sed -n 's/.*"content":"\(.*\)"},"type":"user".*/\1/p' <<<"$line")
    echo "{\"type\":\"user\",\"uuid\":\"u$nmsg\",\"isReplay\":true,\"parent_tool_use_id\":null,\"message\":{\"role\":\"user\",\"content\":\"$c\"}}"
  fi
  if [[ "$line" == *SLOW* ]]; then
    se '{"type":"message_start"}'
    se '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'
    se '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Working"}}'
    # Wait for an interrupt like the real CLI (which ends the turn with an error result).
    if read -t 30 -r next; then
      printf '%s\n' "STDIN $next" >> "$log"
      if [[ "$next" == *'"interrupt"'* ]]; then
        [[ "$line" == *NOINT* ]] && { sleep 30; continue; }
        echo '{"type":"control_response","response":{"subtype":"success","request_id":"x","response":{"still_queued":[]}}}'
        echo '{"type":"result","subtype":"error_during_execution","is_error":true,"result":null,"permission_denials":[]}'
      fi
    fi
    continue
  fi
  if [[ "$line" == *'"content":"/compact'* ]]; then
    echo '{"type":"system","subtype":"status","status":"compacting","session_id":"x"}'
    sleep 0.2
    echo '{"type":"system","subtype":"compact_boundary","compact_metadata":{"trigger":"manual","pre_tokens":19123,"post_tokens":6673}}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"","permission_denials":[]}'
    continue
  fi
  if [[ "$line" == *CTRLPLAN* ]]; then
    echo '{"type":"control_request","request_id":"p1","request":{"subtype":"can_use_tool","tool_name":"ExitPlanMode","input":{"plan":"# Plan\n1. Do it\n2. Test it"},"tool_use_id":"t1","requires_user_interaction":true}}'
    read -r ans
    printf '%s\n' "STDIN $ans" >> "$log"
    echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[]}'
    continue
  fi
  if [[ "$line" == *CTRLASK* ]]; then
    echo '{"type":"control_request","request_id":"q1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which color?","header":"Color","options":[{"label":"Red","description":"warm"},{"label":"Blue","description":"cool"}],"multiSelect":false},{"question":"Which sizes?","header":"Size","options":[{"label":"S","description":""},{"label":"M","description":""},{"label":"L","description":""}],"multiSelect":true}]},"tool_use_id":"t1"}}'
    read -r ans
    printf '%s\n' "STDIN $ans" >> "$log"
    echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[]}'
    continue
  fi
  if [[ "$line" == *CTX* ]]; then
    echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.0548,"usage":{"input_tokens":10,"cache_read_input_tokens":900000,"cache_creation_input_tokens":100,"iterations":[{"input_tokens":5,"cache_read_input_tokens":1000,"cache_creation_input_tokens":0},{"input_tokens":20,"cache_read_input_tokens":879980,"cache_creation_input_tokens":0}]},"modelUsage":{"fake":{"contextWindow":1000000}},"permission_denials":[]}'
    continue
  fi
  if [[ "$line" == *TOOLS* ]]; then
    tu() { echo "{\"type\":\"assistant\",\"parent_tool_use_id\":null,\"message\":{\"content\":[{\"type\":\"tool_use\",\"id\":\"$1\",\"name\":\"$2\",\"input\":$3}]}}"; }
    tr() { echo "{\"type\":\"user\",\"parent_tool_use_id\":null,\"message\":{\"content\":[{\"type\":\"tool_result\",\"tool_use_id\":\"$1\",\"content\":$2}]},\"tool_use_result\":$3}"; }
    tu r1 Read '{"file_path":"a.txt"}'
    tr r1 '"1\tone\n2\ttwo"' '{"type":"text","file":{"numLines":42}}'
    tu e1 Edit '{"file_path":"a.txt","old_string":"two","new_string":"2"}'
    tr e1 '"updated"' '{"structuredPatch":[{"oldStart":1,"oldLines":3,"newStart":1,"newLines":3,"lines":[" one","-two","+2"," three"]}]}'
    tu b1 Bash '{"command":"ls"}'
    tr b1 '"x"' '{"stdout":"a.txt\nb.txt\nc.txt\nd.txt\ne.txt\nf.txt\ng.txt\nh.txt\ni.txt\nj.txt","stderr":""}'
    tu t1 TodoWrite '{"todos":[{"content":"Plan","status":"completed","activeForm":"Planning"},{"content":"Build","status":"in_progress","activeForm":"Building"},{"content":"Ship","status":"pending","activeForm":"Shipping"}]}'
    tr t1 '"ok"' '{}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[]}'
    continue
  fi
  if [[ "$line" == *CTRLPERM* ]]; then
    # Synchronous permission prompts: two requests, then act on the answers.
    echo '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"a.txt"}}]}}'
    echo '{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Edit","input":{"file_path":"a.txt","old_string":"one\ntwo","new_string":"one\n2"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"t1"}}'
    echo '{"type":"control_request","request_id":"r2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"npm test","description":"Run tests"},"tool_use_id":"t2"}}'
    for _ in 1 2; do
      read -r ans
      printf '%s\n' "STDIN $ans" >> "$log"
    done
    echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[{"tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"npm test"}}]}'
    continue
  fi
  if [[ "$line" == *TABLE* ]]; then
    se '{"type":"message_start"}'
    se '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'
    for chunk in 'Intro\n| Act' 'ion | Effect |\n|---|' '---|\n| `add` | Adds one |\n' '\nAfter\n\n| K | V |\n|---|---|\n| a | 1 |'; do
      se "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"$chunk\"}}"
    done
    se '{"type":"content_block_stop","index":0}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[]}'
    continue
  fi
  if [[ "$line" == *CODE* ]]; then
    se '{"type":"message_start"}'
    se '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'
    for chunk in 'Look:\n```j' 's\nconst x = 1;\nfunction f() { return x; }\n```\n\n```py\ndef g():\n    return None\n```\n' '```nosuchlang\nzzz\n```'; do
      se "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"$chunk\"}}"
    done
    se '{"type":"content_block_stop","index":0}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[]}'
    continue
  fi
  if [[ "$line" == *DRIP* ]]; then
    se '{"type":"message_start"}'
    se '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'
    se '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"first\n"}}'
    sleep 0.5
    for i in 1 2 3 4 5; do
      se "{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"more $i\\n\"}}"
    done
    echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","permission_denials":[]}'
    continue
  fi
  if [[ "$line" == *PERM* ]]; then
    echo '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"a.txt"}}]}}'
    echo '{"type":"result","subtype":"success","is_error":false,"result":"blocked","permission_denials":[{"tool_name":"Edit","tool_use_id":"t1","tool_input":{"file_path":"a.txt"}},{"tool_name":"Bash","tool_use_id":"t2","tool_input":{"command":"npm test"}}]}'
    continue
  fi
  se '{"type":"message_start"}'
  se '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'
  se '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello **wor"}}'
  se '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ld**\nsecond line"}}'
  se '{"type":"content_block_stop","index":0}'
  echo '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"text","text":"Hello **world**\nsecond line"}]}}'
  echo '{"type":"assistant","parent_tool_use_id":null,"message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"src/main.c"}}]}}'
  echo '{"type":"stream_event","parent_tool_use_id":"t9","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"SUBAGENT NOISE"}}}'
  echo '{"type":"user","parent_tool_use_id":null,"message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true,"content":"File does not exist."}]}}'
  se '{"type":"message_start"}'
  se '{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}'
  se '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Done."}}'
  se '{"type":"content_block_stop","index":0}'
  echo "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"Done.\",\"session_id\":\"$sid\",\"permission_denials\":[]}"
done
