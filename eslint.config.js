import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['**/dist/**', '**/coverage/**', '**/node_modules/**', '**/vendor/**', 'vendor/**', '**/venv/**', '**/__pycache__/**', '**/test-results/**', '**/.vite/**', '**/target/**', '**/src-tauri/resources/**', 'benchmarks/versus/corpus/**'] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['e2e/**/*.{js,mjs,ts}'],
    languageOptions: {
      globals: {
        process: 'readonly'
      }
    }
  },
  {
    files: ['bin/**/*.mjs'],
    languageOptions: {
      globals: { process: 'readonly', setTimeout: 'readonly', clearTimeout: 'readonly' }
    }
  },
  {
    files: ['benchmarks/**/*.mjs'],
    languageOptions: {
      globals: { process: 'readonly', console: 'readonly', setTimeout: 'readonly', clearTimeout: 'readonly' }
    }
  }
);
