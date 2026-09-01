// Installed by quality-gate. Edit freely -- it is yours once it lands here.
//
// Needs: npm i -D eslint @eslint/js typescript-eslint eslint-plugin-vue
import js from '@eslint/js'
import pluginVue from 'eslint-plugin-vue'
import ts from 'typescript-eslint'

export default ts.config(
  { ignores: ['dist/**', 'coverage/**', '.cache/**'] },
  js.configs.recommended,
  ...ts.configs.recommended,
  ...pluginVue.configs['flat/recommended'],
  {
    // <script lang="ts"> inside .vue needs the TS parser handed to vue-eslint-parser.
    files: ['*.vue', '**/*.vue'],
    languageOptions: {
      parserOptions: { parser: '@typescript-eslint/parser' },
    },
  },
)
