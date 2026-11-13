// Development-only checks for tools/gen-icons.mjs. Node is not used on the workstation.
import assert from 'node:assert/strict';
import { stripHtmlComments, stripSvgComments, jsSingleQuoted, svgInner, iconRecord } from '../tools/gen-icons.mjs';

function evalLiteral(literal) {
  return Function(`"use strict"; return ${literal};`)();
}

assert.equal(jsSingleQuoted('plain'), "'plain'");
assert.equal(evalLiteral(jsSingleQuoted("it's")), "it's");
assert.equal(evalLiteral(jsSingleQuoted('a\\b')), 'a\\b');
assert.equal(evalLiteral(jsSingleQuoted("a\\'b")), "a\\'b");
assert.equal(evalLiteral(jsSingleQuoted('trail\\')), 'trail\\');
assert.equal(evalLiteral(jsSingleQuoted("\\'")), "\\'");

const bypass = '<!<!---->-->';
const open = bypass.indexOf('<!--');
const close = bypass.indexOf('-->', open + 4);
const onePass = bypass.slice(0, open) + bypass.slice(close + 3);
assert.equal(onePass, '<!-->');
assert.equal(stripSvgComments(bypass), '');
assert.equal(stripSvgComments('<!-- closed -->keep'), 'keep');
assert.equal(stripSvgComments('<!-- a --><!-- b -->tail'), 'tail');
assert.equal(stripSvgComments('keep <!-- unclosed <script>'), 'keep ');
assert.equal(stripSvgComments('no comment'), 'no comment');
assert.equal(stripSvgComments('a<!-->b'), 'ab');
assert.equal(stripSvgComments('a<!--->b'), 'ab');
assert.equal(stripSvgComments('a<!--->b<!-->c'), 'abc');
assert.equal(stripSvgComments, stripHtmlComments);

const shared = [
  ['a<!-- x -->b', 'ab'],
  ['a<!-->b', 'ab'],
  ['a<!--->b', 'ab'],
  ['a<!-- x --!>b', 'ab'],
  ['a<!--unclosed <path d="1"/>', 'a'],
  ['<!<!---->-->x', 'x'],
  ['<<!-- -->!--<path/>-->y', 'y'],
  ['<path d="1"/>', '<path d="1"/>'],
];
for (const [input, expected] of shared) {
  assert.equal(stripHtmlComments(input), expected);
  assert.equal(stripSvgComments(input), expected);
}

const lucide = [
  '<!-- @license lucide-static -->',
  '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">',
  '  <path d="M20 6 9 17l-5-5" />',
  '</svg>',
  '',
].join('\n');
assert.equal(
  iconRecord('check', 'check', lucide),
  ` check:'<path d="M20 6 9 17l-5-5"/>', // check`
);

const hostile = '<svg><!<!---->--><path d="a\\\'b" /><!-- <script>alert(1)</script> --></svg>';
const inner = svgInner(hostile);
assert.equal(inner.includes('<!--'), false);
assert.equal(inner.includes('<script'), false);
const line = iconRecord('check', 'check', hostile);
assert.equal(Function(`"use strict"; return ({${line}\n});`)().check, inner);

const unclosed = '<svg><path d="M0 0"/><!-- <script>alert(1)</script></svg>';
assert.equal(svgInner(unclosed), '<path d="M0 0"/>');
assert.equal(svgInner('<svg><!<!---->--><path d="M0 0"/></svg>'), '<path d="M0 0"/>');
assert.equal(svgInner('<svg><!--><path d="M0 0"/></svg>'), '<path d="M0 0"/>');
assert.equal(svgInner('<svg><!---><path d="M0 0"/></svg>'), '<path d="M0 0"/>');
assert.equal(svgInner('<svg><!-- note --><path d="M0 0" /></svg>'), '<path d="M0 0"/>');
assert.equal(svgInner('<svg><!-- note --!><path d="M0 0" /></svg>'), '<path d="M0 0"/>');

console.log('gen-icons tests passed');
