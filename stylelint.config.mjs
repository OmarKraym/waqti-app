// CSS rules that keep the design system honest (CONVENTIONS.md). Run: npm run lint:css
// Tokens live only in src/styles/tokens.css; every other file uses them (no literal colours, sizes, radii, layers).
const BEM = /^(u-)?[a-z][a-z0-9]*(-[a-z0-9]+)*(__[a-z0-9]+(-[a-z0-9]+)*)?(--[a-z0-9]+(-[a-z0-9]+)*)?$/;
const TOKEN = '/^var\\(--[\\w-]+\\)$/';

export default {
  rules: {
    'declaration-no-important': true,
    'selector-class-pattern': [BEM, { message: (s) => `"${s}" is not a BEM class (block__element--modifier, is-/has- state, u- utility)` }],
    // Right-to-left first: logical properties only
    'property-disallowed-list': [['/^(margin|padding|border)-(left|right)/', '/^(left|right)$/', 'float', 'clear']],
    'declaration-property-value-disallowed-list': {
      'text-align': ['left', 'right'],
      '/^(margin|padding|gap|row-gap|column-gap)(-.*)?$/': ['/(^|[\\s(,])-?\\d*\\.?\\d+(px|rem)\\b/'],
    },
    // Strict values: tokens only
    'color-no-hex': true,
    'color-named': 'never',
    'function-disallowed-list': ['rgb', 'rgba', 'hsl', 'hsla'],
    'declaration-property-value-allowed-list': {
      'font-size': ['/^var\\(--(font-size-[\\w-]+|clock-size|time-size)\\)$/', 'inherit'],
      '/^border(-[a-z]+)*-radius$/': ['/^(0|var\\(--radius-[\\w-]+\\))( (0|var\\(--radius-[\\w-]+\\)))*$/'],
      'z-index': ['/^var\\(--z-[\\w-]+\\)$/'],
      '/^(color|background-color|border-color|border-(top|bottom|inline-start|inline-end|block-start|block-end)-color|outline-color|fill|stroke)$/':
        [TOKEN, 'transparent', 'currentColor', 'currentcolor', 'inherit', 'none'],
    },
  },
  overrides: [
    {
      files: ['**/tokens.css'],
      rules: {
        'color-no-hex': null, 'function-disallowed-list': null, 'declaration-property-value-allowed-list': null,
        'declaration-property-value-disallowed-list': null,
      },
    },
  ],
};
