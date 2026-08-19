import js from '@eslint/js';
import reactHooks from 'eslint-plugin-react-hooks';
import reactRefresh from 'eslint-plugin-react-refresh';
import tseslint from 'typescript-eslint';

export default tseslint.config(
  { ignores: ['**/dist/**', '**/coverage/**', '**/node_modules/**', '**/vendor/**', 'vendor/**', '**/venv/**', '**/__pycache__/**', '**/test-results/**', '**/.vite/**', '**/target/**', '**/src-tauri/resources/**'] },
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
      globals: { process: 'readonly', setTimeout: 'readonly' }
    }
  },
  {
    files: ['benchmarks/**/*.mjs'],
    languageOptions: {
      globals: { process: 'readonly', console: 'readonly', setTimeout: 'readonly', clearTimeout: 'readonly' }
    }
  },
  {
    files: ['src/renderer/**/*.{ts,tsx}'],
    plugins: {
      'react-hooks': reactHooks,
      'react-refresh': reactRefresh
    },
    rules: {
      ...reactHooks.configs.recommended.rules,
      'react-refresh/only-export-components': ['warn', { allowConstantExport: true }]
    }
  }
);
