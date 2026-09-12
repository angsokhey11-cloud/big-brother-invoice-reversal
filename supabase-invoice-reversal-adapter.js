/* ============================================================
   BIG BROTHER ACCOUNTING SYSTEM
   INVOICE REVERSAL — SUPABASE ADAPTER V2
   ============================================================ */

(function () {

  'use strict';


  const SUPABASE_URL =
    'https://sjfhlaclgmkwwofzstok.supabase.co';


  const SUPABASE_KEY =
    'sb_publishable_w762jR65CWwlO30fKQsYOw_6L9grx8S';


  const SESSION_KEY =
    'BB_SUPABASE_DEV_SESSION_V1';


  let session =
    null;



  /* ==========================================================
     SESSION
     ========================================================== */

  function readSession() {

    try {

      return JSON.parse(
        localStorage.getItem(
          SESSION_KEY
        )
        ||
        'null'
      );

    } catch (_) {

      return null;

    }

  }



  function saveSession(value) {

    session =
      value
      ||
      null;


    try {

      if (!value) {

        localStorage.removeItem(
          SESSION_KEY
        );

        return;

      }


      if (
        !value.expires_at
        &&
        value.expires_in
      ) {

        value.expires_at =

          Math.floor(
            Date.now() / 1000
          )

          +

          Number(
            value.expires_in
          );

      }


      localStorage.setItem(

        SESSION_KEY,

        JSON.stringify(
          value
        )

      );

    } catch (_) {}

  }



  /* ==========================================================
     RESPONSE
     ========================================================== */

  async function parseResponse(response) {

    const text =
      await response.text();


    let data =
      {};


    try {

      data =
        text
          ?
          JSON.parse(text)
          :
          {};

    } catch (_) {

      data = {
        message: text
      };

    }


    if (!response.ok) {

      throw new Error(

        data.message

        ||

        data.error_description

        ||

        data.error

        ||

        (
          'Invoice Reversal database request failed ('
          +
          response.status
          +
          ')'
        )

      );

    }


    return data;

  }



  /* ==========================================================
     REFRESH SESSION
     ========================================================== */

  async function refreshSession() {

    const current =
      readSession();


    if (
      !current?.refresh_token
    ) {

      throw new Error(
        'Please sign in to BIG BROTHER first.'
      );

    }


    const response =
      await fetch(

        SUPABASE_URL
        +
        '/auth/v1/token?grant_type=refresh_token',

        {

          method:
            'POST',

          headers: {

            apikey:
              SUPABASE_KEY,

            'Content-Type':
              'application/json'

          },

          body:
            JSON.stringify({

              refresh_token:
                current.refresh_token

            }),

          cache:
            'no-store'

        }

      );


    const next =
      await parseResponse(
        response
      );


    saveSession(
      next
    );


    return next;

  }



  /* ==========================================================
     ENSURE SESSION
     ========================================================== */

  async function ensureSession() {

    session =
      readSession();


    if (
      !session?.access_token
    ) {

      throw new Error(
        'Please sign in to BIG BROTHER first.'
      );

    }


    const now =
      Math.floor(
        Date.now() / 1000
      );


    if (
      session.expires_at
      &&
      Number(
        session.expires_at
      )
      <
      now + 30
    ) {

      await refreshSession();

    }


    return session;

  }



  /* ==========================================================
     RPC
     ========================================================== */

  async function rpc(
    functionName,
    args = {}
  ) {

    await ensureSession();


    async function request() {

      return fetch(

        SUPABASE_URL
        +
        '/rest/v1/rpc/'
        +
        functionName,

        {

          method:
            'POST',

          headers: {

            apikey:
              SUPABASE_KEY,

            Authorization:
              'Bearer '
              +
              session.access_token,

            'Content-Type':
              'application/json'

          },

          body:
            JSON.stringify(
              args
              ||
              {}
            ),

          cache:
            'no-store'

        }

      );

    }


    let response =
      await request();


    if (
      response.status
      ===
      401
    ) {

      await refreshSession();

      response =
        await request();

    }


    return parseResponse(
      response
    );

  }



  /* ==========================================================
     INVOICE REVERSAL V2
     ========================================================== */

  async function recent(limit = 50) {

    return rpc(

      'bb_invoice_reversal_recent_v2',

      {
        p_limit:
          Number(
            limit
            ||
            50
          )
      }

    );

  }



  async function detail(invoiceNo) {

    return rpc(

      'bb_invoice_reversal_detail_v2',

      {
        p_invoice_no:
          String(
            invoiceNo
            ||
            ''
          )
          .trim()
      }

    );

  }



  async function save(payload) {

    return rpc(

      'bb_invoice_reversal_save_v2',

      {
        p_payload:
          payload
          ||
          {}
      }

    );

  }



  async function accessProfile() {

    return rpc(
      'bb_current_access_profile'
    );

  }



  /* ==========================================================
     EXPORT
     ========================================================== */

  window.BBInvoiceReversalAdapter = {

    rpc,

    recent,

    detail,

    save,

    ensureSession,

    refreshSession,

    readSession,

    accessProfile

  };


})();
