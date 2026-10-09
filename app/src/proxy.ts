import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock. Set GEOBLOCK_COUNTRIES="US,CU,IR,KP,SY" (ISO-3166 alpha-2) on Vercel.
 * Uses the x-vercel-ip-country header that Vercel's edge sets; no-op when unset or not on Vercel.
 */
export function proxy(req: NextRequest) {
  const blocked = (process.env.GEOBLOCK_COUNTRIES || "")
    .split(",")
    .map((c) => c.trim().toUpperCase())
    .filter(Boolean);
  if (blocked.length === 0) return NextResponse.next();
  const country = req.headers.get("x-vercel-ip-country")?.toUpperCase();
  if (country && blocked.includes(country)) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    return NextResponse.rewrite(url);
  }
  return NextResponse.next();
}

export const config = { matcher: ["/((?!_next|blocked|risk|favicon.ico).*)"] };
