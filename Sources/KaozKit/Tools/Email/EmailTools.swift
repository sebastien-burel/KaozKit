import Foundation

/// Mailbox access over IMAP/SMTP. Defaults target **Proton Bridge** (a local
/// server exposing a Proton account as standard IMAP/SMTP with STARTTLS + a
/// self-signed cert + a bridge-specific password). The tools drive `curl`, so
/// STARTTLS, auth and the self-signed cert are handled by curl.
public struct EmailConfig: Sendable {
    /// How TLS is negotiated. Recent Proton Bridge uses **implicit TLS** (SSL —
    /// a `smtps://`/`imaps://` handshake on connect), NOT STARTTLS.
    public enum TLSMode: String, Sendable { case ssl, starttls, none }

    public let host: String
    public let smtpPort: Int
    public let imapPort: Int
    public let username: String
    public let password: String
    public let fromAddress: String
    /// Proton Bridge uses DIFFERENT TLS per protocol: SMTP = implicit (ssl),
    /// IMAP = STARTTLS. Hence separate modes.
    public let smtpTLS: TLSMode
    public let imapTLS: TLSMode
    /// Who a message goes to when the caller names no recipient — the newsletter
    /// case, where the audience is configuration, not a model's choice.
    public let defaultTo: [String]
    /// Who the caller is *allowed* to name. Empty means unconfined (the historical
    /// behaviour). An entry starting with `@` allows a whole domain.
    public let allowedTo: [String]

    public init(
        host: String = "127.0.0.1", smtpPort: Int = 1025, imapPort: Int = 1143,
        username: String, password: String, fromAddress: String,
        smtpTLS: TLSMode = .ssl, imapTLS: TLSMode = .starttls,
        defaultTo: [String] = [], allowedTo: [String] = []
    ) {
        self.host = host
        self.smtpPort = smtpPort
        self.imapPort = imapPort
        self.username = username
        self.password = password
        self.fromAddress = fromAddress
        self.smtpTLS = smtpTLS
        self.imapTLS = imapTLS
        self.defaultTo = defaultTo
        self.allowedTo = allowedTo
    }

    /// A syntactically safe address: exactly one `@` with both halves present,
    /// and none of the characters that would let a value escape its header line.
    /// CR/LF above all — an address is interpolated into `To:`, so a newline in it
    /// is a header-injection vector, not an address. Whitespace matters too: it
    /// would let `evil@attacker.com x@allowed.tld` satisfy a domain rule while the
    /// mail actually goes elsewhere.
    static func isWellFormed(_ address: String) -> Bool {
        guard !address.isEmpty, address.utf8.count <= 254 else { return false }
        guard !address.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F || $0.properties.isWhitespace
        }) else { return false }
        guard !address.contains(where: { "<>,\"();:\\[]".contains($0) }) else { return false }
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
    }

    /// Is `address` within the allowlist? Empty allowlist ⇒ everything, so an
    /// unconfigured host keeps behaving as it always did — but a malformed address
    /// is refused either way. The default recipients are always allowed: naming one
    /// explicitly must not be worse than omitting it.
    func permits(_ address: String) -> Bool {
        guard Self.isWellFormed(address) else { return false }
        if allowedTo.isEmpty { return true }
        let a = address.lowercased()
        if defaultTo.contains(where: { $0.lowercased() == a }) { return true }
        // Compare the actual domain, not a suffix of the whole string: a suffix
        // test is satisfied by anything merely *ending* in the allowed domain.
        let domain = a.split(separator: "@").last.map(String.init) ?? ""
        return allowedTo.contains { rule in
            let r = rule.lowercased()
            return r.hasPrefix("@") ? domain == r.dropFirst() : r == a
        }
    }

    /// URL scheme per mode: implicit TLS uses smtps/imaps; STARTTLS/none use the
    /// plain scheme (STARTTLS then adds --ssl-reqd via `flags`).
    var smtpURL: String { "\(smtpTLS == .ssl ? "smtps" : "smtp")://\(host):\(smtpPort)" }
    func imapURL(_ path: String) -> String { "\(imapTLS == .ssl ? "imaps" : "imap")://\(host):\(imapPort)\(path)" }

    /// curl flags for a protocol: credentials + TLS (accepting the self-signed cert).
    func flags(_ mode: TLSMode) -> [String] {
        var a = password.isEmpty ? [] : ["--user", "\(username):\(password)"]
        switch mode {
        case .ssl: a += ["--insecure"]                    // implicit TLS via smtps/imaps
        case .starttls: a += ["--ssl-reqd", "--insecure"]
        case .none: break
        }
        return a
    }
}

private let curlPath = "/usr/bin/curl"

/// Sends an email through SMTP (Proton Bridge by default).
/// Un fichier porté par le message. `cid` le rend référençable depuis le HTML
/// — `<img src="cid:illustration">` — auquel cas il est inséré en ligne plutôt
/// que listé en pièce jointe.
public struct EmailAttachment: Decodable, Sendable {
    public let filename: String
    public let contentType: String
    public let base64: String
    public let cid: String?
}

public struct SendEmailTool: Tool {
    public let config: EmailConfig
    public init(config: EmailConfig) { self.config = config }

    public let spec = ToolSpec(
        name: "send_email",
        description: """
        Sends an email from the user's mailbox. `to` may be a comma-separated
        list; omit it to use the host's configured recipients. Supply `html` for
        a rich message — `body` is then the plain-text alternative every client
        can fall back to. Returns confirmation or the server error.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "to": { "type": "string", "description": "Recipient address(es), comma-separated. Omit to use the configured default." },
            "subject": { "type": "string" },
            "body": { "type": "string", "description": "Plain-text message body (also the fallback when `html` is given)." },
            "html": { "type": "string", "description": "Optional HTML body. Sent as multipart/alternative alongside `body`." },
            "attachments": {
              "type": "array",
              "description": "Files to carry. Give a `cid` to reference one from the HTML as an img whose src is cid:NAME — it is then inlined rather than listed.",
              "items": {
                "type": "object",
                "properties": {
                  "filename": { "type": "string" },
                  "contentType": { "type": "string", "description": "MIME type, e.g. image/png." },
                  "base64": { "type": "string", "description": "File contents, base64-encoded." },
                  "cid": { "type": "string", "description": "Content-ID, referenced from the HTML as src=cid:NAME. Omit for a plain attachment." }
                },
                "required": ["filename", "contentType", "base64"],
                "additionalProperties": false
              }
            }
          },
          "required": ["subject", "body"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let to: String?
        let subject: String
        let body: String
        let attachments: [EmailAttachment]?
        let html: String?
    }

    public func execute(arguments: Data) async throws -> String {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else {
            throw ToolError.invalidArguments(reason: "expected {subject, body, to?, html?, attachments?}")
        }
        let named = (args.to ?? "").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let recipients = named.isEmpty ? config.defaultTo : named
        guard !recipients.isEmpty else {
            throw ToolError.invalidArguments(
                reason: "no recipient: pass `to`, or configure a default (MAIL_TO)")
        }
        // Confinement, like every other actuation tool: the model may name an
        // address, but only one the host already sanctioned.
        if let refused = recipients.first(where: { !config.permits($0) }) {
            throw ToolError.execution(
                message: "send_email refused: \(refused) is not an allowed recipient")
        }
        let message = Self.rfc822(
            from: config.fromAddress, to: recipients.joined(separator: ", "),
            subject: args.subject, body: args.body, html: args.html,
            attachments: args.attachments ?? [])
        var curlArgs = [
            "--silent", "--show-error",
            "--url", config.smtpURL,
            "--mail-from", config.fromAddress,
        ]
        for r in recipients { curlArgs += ["--mail-rcpt", r] }
        curlArgs += ["--upload-file", "-"]
        curlArgs += config.flags(config.smtpTLS)

        let (exit, output) = await Subprocess.run(
            curlPath, curlArgs, stdin: Data(message.utf8), timeout: 60)
        guard exit == 0 else {
            throw ToolError.execution(message: "send_email failed (curl \(exit)): \(output.prefix(500))")
        }
        return "email sent to \(recipients.joined(separator: ", "))"
    }

    /// Build the message. With `html`, a `multipart/alternative` carrying the
    /// plain text first and the HTML second (clients pick the last part they
    /// understand). Bodies are base64'd rather than sent raw: it keeps every line
    /// short (an HTML template blows past RFC 5322's 998-char limit), and removes
    /// any chance of a line starting with `.` or a stray CR ending the DATA phase
    /// early — curl does not dot-stuff for us.
    static func rfc822(
        from: String, to: String, subject: String, body: String, html: String?,
        attachments: [EmailAttachment] = []
    ) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var head = [
            "From: \(headerSafe(from))",
            "To: \(headerSafe(to))",
            "Subject: \(encodeHeader(headerSafe(subject)))",
            "Date: \(df.string(from: Date()))",
            "MIME-Version: 1.0",
        ]
        guard html != nil || !attachments.isEmpty else {
            head += [
                "Content-Type: text/plain; charset=utf-8",
                "Content-Transfer-Encoding: base64",
                "",
                base64Body(body),
            ]
            return head.joined(separator: "\r\n") + "\r\n"
        }

        // Le corps : texte seul, ou l'alternative texte/HTML.
        var content: [String]
        if let html {
            // Unguessable, so it cannot occur inside a body we are quoting.
            let alt = "=_kaoz_alt_\(UUID().uuidString)"
            content = [
                "Content-Type: multipart/alternative; boundary=\"\(alt)\"",
                "",
                "--\(alt)",
                "Content-Type: text/plain; charset=utf-8",
                "Content-Transfer-Encoding: base64",
                "",
                base64Body(body),
                "--\(alt)",
                "Content-Type: text/html; charset=utf-8",
                "Content-Transfer-Encoding: base64",
                "",
                base64Body(html),
                "--\(alt)--",
            ]
        } else {
            content = [
                "Content-Type: text/plain; charset=utf-8",
                "Content-Transfer-Encoding: base64",
                "",
                base64Body(body),
            ]
        }

        if attachments.isEmpty {
            return (head + content).joined(separator: "\r\n") + "\r\n"
        }

        // `related` quand une pièce est référencée depuis le HTML : c'est ce qui
        // fait résoudre `cid:` au client. `mixed` sinon, pour une vraie pièce
        // jointe listée à part.
        let inline = attachments.contains { $0.cid != nil }
        let outer = "=_kaoz_rel_\(UUID().uuidString)"
        head += [
            "Content-Type: multipart/\(inline ? "related" : "mixed"); boundary=\"\(outer)\"",
            "",
            "--\(outer)",
        ]
        var parts = content
        for file in attachments {
            let name = headerSafe(file.filename)
            parts += [
                "--\(outer)",
                "Content-Type: \(headerSafe(file.contentType)); name=\"\(name)\"",
                "Content-Transfer-Encoding: base64",
            ]
            if let cid = file.cid {
                parts += [
                    "Content-ID: <\(headerSafe(cid))>",
                    "Content-Disposition: inline; filename=\"\(name)\"",
                ]
            } else {
                parts.append("Content-Disposition: attachment; filename=\"\(name)\"")
            }
            // Ré-encodé depuis les octets : ce qui arrive peut être sur une seule
            // ligne, et une ligne de 2 Mo ne passe aucun serveur SMTP.
            parts += ["", rewrap(file.base64)]
        }
        parts.append("--\(outer)--")
        return (head + parts).joined(separator: "\r\n") + "\r\n"
    }

    /// Recoupe un base64 en lignes de 76 caractères, comme l'exige RFC 2045.
    static func rewrap(_ base64: String) -> String {
        let clean = base64.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: clean, options: [.ignoreUnknownCharacters]) else {
            return clean
        }
        return data.base64EncodedString(options: [
            .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed,
        ])
    }

    /// Flatten anything that could end a header line early. A header value is
    /// terminated by CRLF, so a CR or LF inside one lets the caller append headers
    /// of its own — a `Bcc:`, say. The subject is model-written and may echo text
    /// the model just read on the web, so this is not a theoretical caller.
    /// Folding to a space (rather than rejecting) keeps an innocent multi-line
    /// subject working, while leaving nothing injectable behind.
    static func headerSafe(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.map {
            ($0.value < 0x20 || $0.value == 0x7F) ? " " : $0
        }))
    }

    /// base64, wrapped at 76 columns as MIME requires.
    private static func base64Body(_ s: String) -> String {
        Data(s.utf8).base64EncodedString(options: [
            .lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed,
        ])
    }

    /// RFC 2047 encoded-word for a header that isn't pure ASCII — without it an
    /// accented subject arrives as mojibake. Split on character boundaries so a
    /// multi-byte glyph is never cut in half, and keep each word under the 75-char
    /// limit (45 raw bytes → 60 base64 chars + 12 of syntax).
    static func encodeHeader(_ s: String) -> String {
        guard s.contains(where: { !$0.isASCII }) else { return s }
        var words: [String] = []
        var chunk = [UInt8]()
        for ch in s {
            let bytes = Array(String(ch).utf8)
            if chunk.count + bytes.count > 45 {
                words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=")
                chunk = []
            }
            chunk += bytes
        }
        if !chunk.isEmpty {
            words.append("=?UTF-8?B?\(Data(chunk).base64EncodedString())?=")
        }
        // Folded continuation: CRLF + a space is how a long header wraps.
        return words.joined(separator: "\r\n ")
    }
}

/// Reads the most recent messages from INBOX over IMAP (Proton Bridge default),
/// returning best-effort parsed { from, subject, date, snippet } per message.
public struct ReadEmailTool: Tool {
    public let config: EmailConfig
    public init(config: EmailConfig) { self.config = config }

    public let spec = ToolSpec(
        name: "read_email",
        description: """
        Reads the most recent messages from the INBOX (default 5, max 20),
        newest first, returning { from, subject, date, snippet } for each.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "limit": { "type": "integer", "description": "How many recent messages (default 5).", "minimum": 1, "maximum": 20 }
          },
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable { let limit: Int? }

    public func execute(arguments: Data) async throws -> String {
        let limit = min((try? JSONDecoder().decode(Args.self, from: arguments))?.limit ?? 5, 20)

        // Message count via STATUS.
        let (se, statusOut) = await Subprocess.run(
            curlPath, ["--silent", "--url", config.imapURL("/INBOX"),
                       "--request", "STATUS INBOX (MESSAGES)"] + config.flags(config.imapTLS))
        guard se == 0 else {
            throw ToolError.execution(message: "read_email (status) failed (curl \(se)): \(statusOut.prefix(300))")
        }
        guard let count = Self.parseCount(statusOut), count > 0 else { return "[]" }

        // Fetch the last `limit` messages by sequence number, newest first.
        var results: [[String: Any]] = []
        let start = max(1, count - limit + 1)
        for seq in stride(from: count, through: start, by: -1) {
            let (fe, raw) = await Subprocess.run(
                curlPath, ["--silent", "--url", config.imapURL("/INBOX;MAILINDEX=\(seq)")] + config.flags(config.imapTLS))
            if fe == 0, !raw.isEmpty { results.append(Self.parseMessage(raw)) }
        }
        let json = (try? JSONSerialization.data(withJSONObject: results))
            .flatMap { String(data: $0, encoding: .utf8) }
        return json ?? "[]"
    }

    /// `* STATUS INBOX (MESSAGES 42)` → 42.
    private static func parseCount(_ s: String) -> Int? {
        guard let r = s.range(of: "MESSAGES ") else { return nil }
        let tail = s[r.upperBound...].prefix { $0.isNumber }
        return Int(tail)
    }

    /// Extract From/Subject/Date headers and a short body snippet from a raw
    /// RFC822 message (best-effort — the agent gets structured fields to act on).
    private static func parseMessage(_ raw: String) -> [String: Any] {
        var headers: [String: String] = [:]
        let parts = raw.components(separatedBy: "\r\n\r\n")
        let headerBlock = parts.first ?? raw
        for line in headerBlock.components(separatedBy: "\r\n") where line.contains(":") {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2 {
                let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
                if ["from", "subject", "date"].contains(key), headers[key] == nil {
                    headers[key] = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let body = parts.count > 1 ? parts[1...].joined(separator: "\r\n\r\n") : ""
        return [
            "from": headers["from"] ?? "",
            "subject": headers["subject"] ?? "",
            "date": headers["date"] ?? "",
            "snippet": String(cleanSnippet(body).prefix(300)),
        ]
    }

    /// Make a readable snippet: decode quoted-printable, strip HTML tags, and
    /// collapse whitespace (email bodies are usually QP-encoded and often HTML).
    private static func cleanSnippet(_ raw: String) -> String {
        var s = decodeQuotedPrintable(raw)
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode quoted-printable to UTF-8 (=XX byte escapes, =\r\n soft breaks).
    private static func decodeQuotedPrintable(_ s: String) -> String {
        let arr = Array(s.utf8)
        var bytes: [UInt8] = []
        var i = 0
        func hex(_ b: UInt8) -> Int? {
            switch b {
            case 0x30...0x39: return Int(b - 0x30)
            case 0x41...0x46: return Int(b - 0x41 + 10)
            case 0x61...0x66: return Int(b - 0x61 + 10)
            default: return nil
            }
        }
        while i < arr.count {
            if arr[i] == UInt8(ascii: "="), i + 2 < arr.count {
                if arr[i + 1] == 0x0D, arr[i + 2] == 0x0A { i += 3; continue }   // soft line break
                if let hi = hex(arr[i + 1]), let lo = hex(arr[i + 2]) {
                    bytes.append(UInt8(hi * 16 + lo)); i += 3; continue
                }
            }
            bytes.append(arr[i]); i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
