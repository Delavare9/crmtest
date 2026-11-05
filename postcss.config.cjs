// PostCSS для Mantine: preset даёт миксины и функции rem()/em() в CSS-модулях,
// simple-vars — точки перелома ($mantine-breakpoint-*) как переменные.
module.exports = {
  plugins: {
    "postcss-preset-mantine": {},
    "postcss-simple-vars": {
      variables: {
        "mantine-breakpoint-xs": "36em",
        "mantine-breakpoint-sm": "48em",
        "mantine-breakpoint-md": "62em",
        "mantine-breakpoint-lg": "75em",
        "mantine-breakpoint-xl": "88em",
      },
    },
  },
};
