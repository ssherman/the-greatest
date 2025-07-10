import resolve from "@rollup/plugin-node-resolve"

export default [
  // Main application bundle
  {
    input: "app/javascript/application.js",
    output: {
      file: "app/assets/builds/application.js",
      format: "iife",
      name: "Application",
      inlineDynamicImports: true,
      sourcemap: true
    },
    plugins: [
      resolve()
    ]
  },
  // Domain-specific bundles
  {
    input: "app/javascript/books.js",
    output: {
      file: "app/assets/builds/books.js",
      format: "iife",
      name: "BooksApp",
      inlineDynamicImports: true,
      sourcemap: true
    },
    plugins: [
      resolve()
    ]
  },
  {
    input: "app/javascript/music.js",
    output: {
      file: "app/assets/builds/music.js",
      format: "iife",
      name: "MusicApp",
      inlineDynamicImports: true,
      sourcemap: true
    },
    plugins: [
      resolve()
    ]
  },
  {
    input: "app/javascript/movies.js",
    output: {
      file: "app/assets/builds/movies.js",
      format: "iife",
      name: "MoviesApp",
      inlineDynamicImports: true,
      sourcemap: true
    },
    plugins: [
      resolve()
    ]
  },
  {
    input: "app/javascript/games.js",
    output: {
      file: "app/assets/builds/games.js",
      format: "iife",
      name: "GamesApp",
      inlineDynamicImports: true,
      sourcemap: true
    },
    plugins: [
      resolve()
    ]
  }
]
