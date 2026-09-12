// Phase 5 fixture: mixed sequential calls (echo then stream) in one fixture,
// exercising distinct ids back to back with no crosstalk.
(async () => {
  const a = await host.echo("first");
  print("echo:" + a);
  const full = await host.stream("p", (d) => { print("delta:" + d); });
  print("stream:" + full);
})();
