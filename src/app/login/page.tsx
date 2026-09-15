import { LoginPageClient } from "./login-page-client";

// This page reads the `next`/`error` search params (see login-page-client.tsx)
// via useSearchParams(). Left as the default static rendering, Next.js has no
// request to read those params from at build time and silently ships an
// EMPTY page — the whole form bails out to client-side-only rendering
// (visible in the built HTML as a BAILOUT_TO_CLIENT_SIDE_RENDERING marker)
// until React hydrates in the browser. On a slow connection — exactly the
// "بعض المندوبين استخدامهم للتكنولوجيا والموبايل محدود" case the spec calls
// out — that's a blank white screen where the login form should be. Forcing
// this route to render per-request fixes it: real content ships in the
// initial HTML every time.
export const dynamic = "force-dynamic";

export default function LoginPage() {
  return <LoginPageClient />;
}
