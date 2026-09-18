"use client";

/**
 * Catches an error thrown by the root layout itself (src/app/layout.tsx) —
 * the one place `src/app/error.tsx` can't reach, since that boundary is
 * nested *inside* the layout it's rendered by. The root layout here does no
 * data fetching (just static chrome: Toaster, RefreshToHome, globals.css),
 * so this should be effectively unreachable in practice — it exists as a
 * safety net so a future change to that layout doesn't regress all the way
 * back to a bare unstyled crash. Per Next.js's own convention, this file
 * replaces the root layout when it fires, so it has to render its own
 * <html>/<body> rather than relying on layout.tsx (which is exactly why it
 * can't reuse src/app/error.tsx's markup/components directly).
 */
export default function GlobalError({
  error,
}: {
  error: Error & { digest?: string };
}) {
  return (
    <html lang="ar" dir="rtl">
      <body
        style={{
          minHeight: "100vh",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontFamily: "Tahoma, 'Segoe UI', Arial, sans-serif",
          background: "#fdfcf9",
          color: "#1f1a0d",
          padding: "1rem",
        }}
      >
        <div style={{ textAlign: "center", maxWidth: 420 }}>
          <h1 style={{ fontSize: "1.125rem", fontWeight: 700, marginBottom: "0.5rem" }}>
            حدث خطأ غير متوقع
          </h1>
          <p style={{ fontSize: "0.875rem", color: "#6b6355", marginBottom: "1rem" }}>
            حاول تحديث الصفحة. لو استمرت المشكلة أرسل الكود ده لفريق الدعم الفني.
          </p>
          {error.digest && (
            <code
              style={{
                display: "inline-block",
                fontSize: "0.75rem",
                background: "#f2efe6",
                border: "1px solid #e3ddc9",
                borderRadius: 6,
                padding: "0.5rem 0.75rem",
              }}
            >
              {error.digest}
            </code>
          )}
        </div>
      </body>
    </html>
  );
}
