// Workaround for code-server 4.140: with --proxy-domain it normalizes the domain to a
// pattern such as "{{port}}-dev.example.com", but getCookieDomain() then compares the
// request host with that pattern including "{{port}}", which never matches. The login
// cookie therefore stays on the IDE host and the per-port hostnames answer 401.
// This strips the label that holds {{port}} before the comparison, so one login on the
// IDE host also covers the port hostnames (cookie Domain = the parent domain).
//
// Fails the image build if the code changed (new code-server version): then check
// whether the bug is fixed upstream and delete this patch and its Dockerfile lines.
const fs = require("fs");
const file = "/app/code-server/out/node/http.js";
const src = fs.readFileSync(file, "utf8");
const from =
  "        if (host.endsWith(domain) && domain.length < host.length) {\n" +
  "            host = domain;\n" +
  "        }";
const to =
  '        const plain = domain.replace(/^[^.]*\\{\\{port\\}\\}[^.]*\\./, "");\n' +
  "        if (host.endsWith(plain) && plain.length < host.length) {\n" +
  "            host = plain;\n" +
  "        }";
if (src.split(from).length !== 2) {
  console.error("code-server cookie-domain patch: target not found exactly once; code-server changed, review patches/");
  process.exit(1);
}
fs.writeFileSync(file, src.replace(from, () => to));
console.log("patched " + file);
