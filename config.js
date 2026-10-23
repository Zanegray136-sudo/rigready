// BenchLog settings.
// Leave the two Supabase values empty to run in DEMO mode (sample data, saved only in your browser).
// Paste your values from Supabase → Project Settings → API to go live with team log-ins.
// The anon/publishable key is meant to be public — your data is protected by the database rules in schema.sql.
window.BENCHLOG_CONFIG = {
  SUPABASE_URL: "",          // e.g. "https://abcdefgh.supabase.co"
  SUPABASE_ANON_KEY: "",     // the "anon" / "publishable" key

  APP_NAME: "BenchLog",      // rename the app here
  FAULT_ALERT_DAYS: 60,      // alert when an item has been faulty this long (60 ≈ 2 months)
  DUE_SOON_DAYS: 14          // flag services as "due soon" this many days ahead
};
