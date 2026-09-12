// weather.js — a KaozKit agent. `web_search` needs BRAVE_API_KEY; without it
// the host drops the tool with a warning and the agent still answers.
export async function run(input) {
  const reply = await host.llm.chat(
    [{ role: "user", content: input.question }],
    { tools: ["current_datetime", "web_search"] }
  );
  await host.memory.save("last question", input.question);
  return { answer: reply };
}
