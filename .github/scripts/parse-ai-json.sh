#!/usr/bin/env bash
# Robustly parse AI output to guaranteed-valid JSON and expose it as a step output.
set -euo pipefail

content="${AI_CONTENT:-}"

# If content is empty/null, try to extract from the raw response using multiple schemas.
if [ -z "${content}" ] || [ "${content}" = "null" ]; then
  content="$(jq -r '
      # OpenAI Responses API: concatenated text
      .output_text
      # Or explicit output content array
      // (.output[0].content[]? | select(.type=="output_text") | .text)
      # Legacy Chat Completions
      // .choices[0].message.content
      // .choices[0].text
      # Some providers (Gemini-style)
      // (.candidates[0].content.parts[]? | .text)
      # Nothing matched
      // empty
    ' <<< "${AI_RESPONSE:-}" 2>/dev/null || echo "")"
fi

# Strip common fenced-code wrappers if present and they wrap the entire payload
if [ -n "${content}" ]; then
  first_line="$(printf "%s" "$content" | head -n1)"
  last_line="$(printf "%s" "$content" | tail -n1)"
  if [[ "$first_line" =~ ^\`\`\`(json)?[[:space:]]*$ ]] && [[ "$last_line" =~ ^\`\`\`[[:space:]]*$ ]]; then
    content="$(printf "%s" "$content" | sed '1d;$d')"
  fi
fi

# If still empty, synthesize a safe default
if [ -z "${content}" ]; then
  content='{
    "actionable": false,
    "summary": "AI triage could not parse a valid response.",
    "missing": ["reproduction steps", "expected vs actual", "environment details"],
    "questions": ["Please provide the missing details listed above."],
    "labels": ["needs-more-info"],
    "confidence": 0
  }'
fi

# Write and validate JSON
printf "%s" "$content" > ai.json

# If validation fails (e.g., stray text), try to extract the first top-level JSON object/array
if ! jq . ai.json >/dev/null 2>&1; then
  extracted="$(python3 - <<'PY' -- "$(cat ai.json)" || true)
import sys
s = sys.argv[1]
stack = []
start = None
for i, ch in enumerate(s):
    if ch in '{[':
        if start is None:
            start = i
        stack.append('}' if ch=='{' else ']')
    elif ch in '}]':
        if stack:
            stack.pop()
            if not stack:
                print(s[start:i+1])
                break
PY
)"
  if [ -n "${extracted:-}" ]; then
    printf "%s" "$extracted" > ai.json
  fi

  # Validate again; on failure, fall back to safe default
  if ! jq . ai.json >/dev/null 2>&1; then
    printf "%s" '{
      "actionable": false,
      "summary": "AI triage returned non-JSON output that could not be parsed.",
      "missing": ["reproduction steps", "expected vs actual", "environment details"],
      "questions": ["Please provide the missing details listed above."],
      "labels": ["needs-more-info"],
      "confidence": 0
    }' > ai.json
  fi
fi

# Publish compact JSON into step output
echo "ai=$(jq -c . ai.json)" >> "$GITHUB_OUTPUT"
