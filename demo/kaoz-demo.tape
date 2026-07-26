# kaoz-demo.tape — VHS script for the KaozKit README GIF
Output kaoz-demo.gif

Set FontSize 26
Set Width 1200
Set Height 640
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
Set Shell "bash"

# Show the agent source first
Type "cat weather.js"
Enter
Sleep 3.5s

# Run it
Type `kaoz weather.js --provider anthropic --model claude-opus-4-8 --input '{"question":"weather in Rennes tomorrow?"}'`
Enter

# Wait for the LLM round-trip (adjust to your real latency)
Sleep 12s
Enter
Sleep 3s
Type `kaoz weather.js --provider apple --input '{"question":"weather in Rennes tomorrow? respond in english."}'`
Enter
Sleep 1s

Sleep 3s
