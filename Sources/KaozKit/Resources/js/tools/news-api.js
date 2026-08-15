// news_search — NewsAPI /v2/everything. The API key is passed in via
// globalThis.__toolConfig.newsApiKey (set by the loader from NEWS_API_KEY);
// it never reaches an agent's machine, like every other secret here.
//
// Returns JSON rather than prose: a language model reads it just as well, and
// a program calling through host.tool.call gets the fields it needs instead of
// having to unpick a formatted list.
import { httpGet } from "./http.js";

export default {
  name: "news_search",
  description:
    "Searches recent news articles with NewsAPI and returns them as a JSON "
    + "array of { source, title, url, summary, published }, most recent first. "
    + "Use for news coverage of a topic over the last weeks.",
  input_schema: {
    type: "object",
    properties: {
      query: { type: "string", description: "The search query." },
      count: {
        type: "integer",
        description: "Number of articles to return (1-100, default 5).",
        minimum: 1, maximum: 100,
      },
      language: {
        type: "string",
        description: "ISO 639-1 language code (default \"en\").",
      },
    },
    required: ["query"],
    additionalProperties: false,
  },
  async run(args) {
    const cfg = globalThis.__toolConfig || {};
    const key = (cfg.newsApiKey || "").trim();
    if (!key) throw new Error("clé API NewsAPI manquante (NEWS_API_KEY)");
    const query = String((args && args.query) || "").trim();
    if (!query) throw new Error("query ne peut pas être vide");
    const count = Math.min(Math.max((args && args.count) || 5, 1), 100);
    const language = String((args && args.language) || "en");

    const base = (cfg.newsApiBaseURL || "https://newsapi.org").replace(/\/+$/, "");
    const url = base + "/v2/everything?q=" + encodeURIComponent(query)
      + "&language=" + encodeURIComponent(language)
      + "&sortBy=publishedAt&pageSize=" + count;
    // En en-tête plutôt qu'en paramètre : la clé ne traverse ni l'URL ni les logs.
    const res = await httpGet(url, { "Accept": "application/json", "X-Api-Key": key });
    if (res.status < 200 || res.status >= 300) throw new Error("HTTP " + res.status);

    let data; try { data = JSON.parse(res.text); } catch (e) { data = {}; }
    if (data.status !== "ok") throw new Error(data.message || "NewsAPI a refusé la requête");
    return (data.articles || []).slice(0, count).map((a) => ({
      source: (a.source && a.source.name) || "NewsAPI",
      title: a.title || "",
      url: a.url || "",
      summary: a.description || a.content || "",
      published: a.publishedAt || "",
    }));
  },
};
