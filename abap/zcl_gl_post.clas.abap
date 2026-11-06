"! GL document posting ICF handler. Implements the gl.post-document REST contract:
"! reads the request body, checks the posting lines balance, mints a GL document id,
"! and always answers HTTP 200 with a gl.post-document.response body.
CLASS zcl_gl_post DEFINITION PUBLIC FINAL CREATE PUBLIC.

  PUBLIC SECTION.
    INTERFACES if_http_extension.

  PRIVATE SECTION.

    TYPES: BEGIN OF ty_gl_line,
             account_id TYPE string,
             direction  TYPE string,
             amount     TYPE string,
           END OF ty_gl_line.
    TYPES tt_gl_line TYPE STANDARD TABLE OF ty_gl_line.

    CLASS-DATA gv_doc_counter TYPE i.

    METHODS get_json_string
      IMPORTING
        iv_json         TYPE string
        iv_key          TYPE string
      RETURNING
        VALUE(rv_value) TYPE string.

    METHODS parse_lines
      IMPORTING
        iv_body         TYPE string
      RETURNING
        VALUE(rt_lines) TYPE tt_gl_line.

    METHODS lines_balanced
      IMPORTING
        it_lines           TYPE tt_gl_line
      RETURNING
        VALUE(rv_balanced) TYPE abap_bool.

    METHODS mint_gl_doc_id
      RETURNING
        VALUE(rv_gl_doc_id) TYPE string.

    METHODS build_response
      IMPORTING
        iv_gl_doc_id   TYPE string
        iv_reference   TYPE string
        iv_status      TYPE string
      RETURNING
        VALUE(rv_json) TYPE string.

    METHODS escape_json_value
      IMPORTING
        iv_in         TYPE string
      RETURNING
        VALUE(rv_out) TYPE string.

ENDCLASS.


CLASS zcl_gl_post IMPLEMENTATION.

  METHOD if_http_extension~handle_request.

    " read -> parse -> validate -> mint id -> respond. Every path, whether parse
    " failure, business-rule rejection or success, ends in HTTP 200 with a
    " gl.post-document.response body; only the JSON "status" value differs.

    DATA: lv_body         TYPE string,
          lv_reference    TYPE string,
          lt_lines        TYPE tt_gl_line,
          lv_count        TYPE i,
          lv_balanced     TYPE abap_bool,
          lv_status       TYPE string,
          lv_gl_doc_id    TYPE string,
          lv_preformatted TYPE string,
          lv_ref_out      TYPE string,
          lv_response     TYPE string.

    lv_gl_doc_id = mint_gl_doc_id( ).
    lv_status    = 'REJECTED'.
    lv_reference = ''.

    TRY.
        lv_body      = server->request->get_cdata( ).
        lv_reference = get_json_string( iv_json = lv_body iv_key = 'reference' ).
        lt_lines     = parse_lines( lv_body ).

        DESCRIBE TABLE lt_lines LINES lv_count.

        IF lv_count >= 2.
          lv_balanced = lines_balanced( lt_lines ).
          IF lv_balanced = abap_true.
            lv_status = 'POSTED'.
          ENDIF.
        ENDIF.

      CATCH cx_root.
        " any parse/runtime failure degrades to REJECTED; the response below still
        " goes out so the caller always gets a schema-valid body.
        lv_status = 'REJECTED'.
    ENDTRY.

    " The ICF service configuration sets x-preformatted-refs.
    lv_preformatted = server->request->get_header_field( name = 'x-preformatted-refs' ).

    lv_ref_out = escape_json_value( lv_reference ).

    lv_response = build_response(
      iv_gl_doc_id = lv_gl_doc_id
      iv_reference = lv_ref_out
      iv_status    = lv_status ).

    server->response->set_header_field( name = 'content-type' value = 'application/json' ).
    server->response->set_status( code = 200 reason = 'OK' ).
    server->response->set_cdata( data = lv_response ).

  ENDMETHOD.


  METHOD get_json_string.

    " Extracts one "key":"value" pair. Every scalar field in both the request and
    " response schemas is a JSON string, so a quoted value is the only shape this
    " needs to handle.

    DATA: lv_key_pat  TYPE string,
          lv_off      TYPE i,
          lv_len      TYPE i,
          lv_tail     TYPE string,
          lv_q1       TYPE i,
          lv_after_q1 TYPE string,
          lv_q2       TYPE i.

    rv_value = ''.

    CONCATENATE '"' iv_key '":' INTO lv_key_pat.

    FIND FIRST OCCURRENCE OF lv_key_pat IN iv_json MATCH OFFSET lv_off MATCH LENGTH lv_len.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    lv_tail = substring( val = iv_json off = lv_off + lv_len ).

    FIND FIRST OCCURRENCE OF '"' IN lv_tail MATCH OFFSET lv_q1.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    lv_after_q1 = substring( val = lv_tail off = lv_q1 + 1 ).

    FIND FIRST OCCURRENCE OF '"' IN lv_after_q1 MATCH OFFSET lv_q2.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    rv_value = substring( val = lv_after_q1 len = lv_q2 ).

  ENDMETHOD.


  METHOD parse_lines.

    " Splits the "lines" JSON array into one substring per {..} object, then reads
    " account_id/direction/amount out of each. Assumes a GL line object is flat (no
    " nested { or [ inside it) -- true for the current GlLine schema.

    DATA: lv_off          TYPE i,
          lv_len          TYPE i,
          lv_tail         TYPE string,
          lv_open         TYPE i,
          lv_after_open   TYPE string,
          lv_close        TYPE i,
          lv_array_body   TYPE string,
          lv_b_open       TYPE i,
          lv_after_b_open TYPE string,
          lv_b_close      TYPE i,
          lv_obj          TYPE string,
          ls_line         TYPE ty_gl_line.

    FIND FIRST OCCURRENCE OF '"lines":' IN iv_body MATCH OFFSET lv_off MATCH LENGTH lv_len.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    lv_tail = substring( val = iv_body off = lv_off + lv_len ).

    FIND FIRST OCCURRENCE OF '[' IN lv_tail MATCH OFFSET lv_open.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    lv_after_open = substring( val = lv_tail off = lv_open + 1 ).

    FIND FIRST OCCURRENCE OF ']' IN lv_after_open MATCH OFFSET lv_close.
    IF sy-subrc <> 0.
      RETURN.
    ENDIF.

    lv_array_body = substring( val = lv_after_open len = lv_close ).

    DO.
      FIND FIRST OCCURRENCE OF '{' IN lv_array_body MATCH OFFSET lv_b_open.
      IF sy-subrc <> 0.
        EXIT.
      ENDIF.

      lv_after_b_open = substring( val = lv_array_body off = lv_b_open + 1 ).

      FIND FIRST OCCURRENCE OF '}' IN lv_after_b_open MATCH OFFSET lv_b_close.
      IF sy-subrc <> 0.
        EXIT.
      ENDIF.

      lv_obj = substring( val = lv_after_b_open len = lv_b_close ).

      CLEAR ls_line.
      ls_line-account_id = get_json_string( iv_json = lv_obj iv_key = 'account_id' ).
      ls_line-direction  = get_json_string( iv_json = lv_obj iv_key = 'direction' ).
      ls_line-amount     = get_json_string( iv_json = lv_obj iv_key = 'amount' ).
      APPEND ls_line TO rt_lines.

      lv_array_body = substring( val = lv_after_b_open off = lv_b_close + 1 ).
    ENDDO.

  ENDMETHOD.


  METHOD lines_balanced.

    " Debits must equal credits, compared as exact packed-decimal values (never
    " float) -- same rule contracts/data-model.md sets for money crossing any other
    " boundary. A line whose direction is neither 'D' nor 'C' forces the document
    " unbalanced rather than being silently dropped from the sum.

    DATA: ls_line      TYPE ty_gl_line,
          lv_amount    TYPE p DECIMALS 2,
          lv_debit     TYPE p DECIMALS 2,
          lv_credit    TYPE p DECIMALS 2,
          lv_all_valid TYPE abap_bool.

    lv_debit     = 0.
    lv_credit    = 0.
    lv_all_valid = abap_true.

    LOOP AT it_lines INTO ls_line.
      lv_amount = ls_line-amount.
      IF ls_line-direction = 'D'.
        lv_debit = lv_debit + lv_amount.
      ELSEIF ls_line-direction = 'C'.
        lv_credit = lv_credit + lv_amount.
      ELSE.
        lv_all_valid = abap_false.
      ENDIF.
    ENDLOOP.

    IF lv_all_valid = abap_true AND lv_debit = lv_credit.
      rv_balanced = abap_true.
    ELSE.
      rv_balanced = abap_false.
    ENDIF.

  ENDMETHOD.


  METHOD mint_gl_doc_id.

    " 'GL' + YYYYMMDDHHMMSS (sy-datum/sy-uzeit, second resolution) + a 2-digit
    " in-process sequence -- 18 chars total, well under the 20-char GlDocId limit.

    DATA: lv_ts    TYPE string,
          lv_seq_n TYPE i,
          lv_seq   TYPE n LENGTH 2.

    gv_doc_counter = gv_doc_counter + 1.
    lv_seq_n = gv_doc_counter MOD 100.
    lv_seq   = lv_seq_n.

    CONCATENATE sy-datum sy-uzeit INTO lv_ts.
    CONCATENATE 'GL' lv_ts lv_seq INTO rv_gl_doc_id.

  ENDMETHOD.


  METHOD build_response.

    " Builds the gl.post-document.response body.

    CONCATENATE '{"gl_doc_id":"' iv_gl_doc_id
                '","reference":"' iv_reference
                '","status":"' iv_status
                '"}'
      INTO rv_json.

  ENDMETHOD.


  METHOD escape_json_value.

    " JSON string escaping: backslash first (so the added escapes are not doubled),
    " then the double quote.

    rv_out = iv_in.
    REPLACE ALL OCCURRENCES OF '\' IN rv_out WITH '\\'.
    REPLACE ALL OCCURRENCES OF '"' IN rv_out WITH '\"'.

  ENDMETHOD.

ENDCLASS.
