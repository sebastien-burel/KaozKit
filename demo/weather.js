// weather.js — a KaozKit agent
export async function run(input) {
  const reply = await host.llm.chat(
    [{ role: "user", content: input.question }],
    { tools: ["current_datetime", "web_search"] }
  );
  await host.memory.save("weather check", input.question);
  return { answer: reply };
}
