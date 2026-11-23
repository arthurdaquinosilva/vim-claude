#!/usr/bin/env bash
# Stand-in for the `claude` CLI used by the tests. Emits canned stream-json.
log="${FAKE_CLAUDE_LOG:-/dev/null}"
printf '%s\n' "ARGS $*" >> "$log"
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

echo "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"$sid\",\"model\":\"fake-model\"}"
se() { echo "{\"type\":\"stream_event\",\"parent_tool_use_id\":null,\"event\":$1}"; }
while IFS= read -r line; do
  printf '%s\n' "STDIN $line" >> "$log"
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
