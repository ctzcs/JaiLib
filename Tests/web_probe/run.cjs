const fs = require('fs');
const path = process.argv[2];
if (!path) throw new Error('Usage: node run.cjs probe.wasm');
const moduleBytes = fs.readFileSync(path);
let memory;
const output = [];
const decoder = new TextDecoder();
const moduleObject = new WebAssembly.Module(moduleBytes);
const instance = new WebAssembly.Instance(moduleObject, {env: {
  memcmp: (left, right, count) => {
    const bytes = new Uint8Array(memory.buffer);
    const a = Number(left), b = Number(right), n = Number(count);
    for (let i = 0; i < n; i++) if (bytes[a+i] !== bytes[b+i]) return bytes[a+i] - bytes[b+i];
    return 0;
  },
  wasm_write_string: (count, pointer) => {
    output.push(decoder.decode(new Uint8Array(memory.buffer, Number(pointer), Number(count))));
  },
  wasm_debug_break: () => { throw new Error('Jai assertion/debug break'); }
}});
memory = instance.exports.memory;
instance.exports.main(0, 0n);
const text = output.join('');
process.stdout.write(text);
if (!text.includes('JaiLib WASM64 CPU PASS') || text.includes('FAIL')) process.exit(1);
