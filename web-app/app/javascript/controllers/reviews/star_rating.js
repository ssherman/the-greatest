// Shared by reviews--widget and reviews--star-input. Mirrors
// Reviews::StarsComponent#star_fills and Review.format_rating, so a rating
// looks the same whether the server rendered it or JavaScript hydrated it.
export const MAX_RATING = 5

// Percent fill of each of the five stars, one decimal.
export function starFills(rating) {
  const value = Math.max(0, Math.min(MAX_RATING, Number(rating) || 0))
  return Array.from({ length: MAX_RATING }, (_, index) =>
    Math.round(Math.max(0, Math.min(1, value - index)) * 1000) / 10
  )
}

// 4 -> "4", 3.5 -> "3.5", 3.75 -> "3.75".
export function formatRating(rating) {
  return String(Number(Number(rating).toFixed(2)))
}
