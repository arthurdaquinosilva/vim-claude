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
    sleep 30
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
