/// The invented VLESS link every test uses — the real shape (xhttp + REALITY,
/// `mode=stream-one`), invented credentials. `uuid`, `pbk` and `sid` are the canaries
/// every redaction assertion greps the output for.
enum Synthetic {
    static let link =
        "vless://11111111-2222-3333-4444-555555555555@proxy.example.com:8443"
        + "?type=xhttp&security=reality&fp=chrome&sni=www.example.com"
        + "&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=74682ba3"
        + "&path=/xhttp&mode=stream-one#Spike%20Exit"
    static let uuid = "11111111-2222-3333-4444-555555555555"
    static let pbk = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
    static let sid = "74682ba3"
    static let secrets = [uuid, pbk, sid]
}
