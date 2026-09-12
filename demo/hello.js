// hello.js — your first KaozKit agent. Runs fully on-device with --provider apple.
//
//   swift run -c release kaoz demo/hello.js --provider apple
//
// No API key, no tool that needs one: `current_datetime` is always there.
export async function run(input) {
  // `input` is null when kaoz runs without --input — hence the `?.`.
  const question = input?.question ?? "What day is it today, and what can you do for me?";
  const reply = await host.llm.chat(
    [{ role: "user", content: question }],
    { tools: ["current_datetime"] }
  );
  return { answer: reply };
}
