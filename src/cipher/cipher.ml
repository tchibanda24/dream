(* This file is part of Dream, released under the MIT license. See LICENSE.md
   for details, or visit https://github.com/aantron/dream.

   Copyright 2021 Anton Bachin *)

(* TODO Review all | exception cases in all code and avoid them as much sa
   possible. *)
(* TODO Support mixture of encryption and signing. *)
(* TODO LATER Switch to AEAD_AES_256_GCM_SIV. See
   https://github.com/mirage/mirage-crypto/issues/111. *)

module Message = Dream_pure.Message

module type Cipher = sig
  val prefix : char
  val name : string
  val encrypt : ?associated_data:string -> secret:string -> string -> string

  val decrypt :
    ?associated_data:string -> secret:string -> string -> string option

  val test_encrypt :
    ?associated_data:string -> secret:string -> nonce:string -> string -> string
end

let encrypt (module Cipher : Cipher) ?associated_data secret plaintext =
  Cipher.encrypt ?associated_data ~secret plaintext

let rec decrypt ((module Cipher : Cipher) as cipher) ?associated_data secrets
    ciphertext =
  match secrets with
  | [] -> None
  | secret :: secrets -> (
    match Cipher.decrypt ?associated_data ~secret ciphertext with
    | Some _ as plaintext -> plaintext
    | None -> decrypt cipher secrets ciphertext)

(* Key is good for ~2.5 years if every request e.g. generates one new signed
   cookie, and the installation is doing 1000 requests per second. *)
module AEAD_AES_256_GCM = struct
  (* Enciphered messages are prefixed with a version. There is only one right
     now, version 0, in which the rest of the message consists of:

     - a 96-bit nonce, as recommended in RFC 5116.
     - ciphertext generated by AEAD_AES_256_GCM (RFC 5116).

     The 256-bit key is "derived" from the given secret by hashing it with
     SHA-256.

     See https://tools.ietf.org/html/rfc5116. *)

  (* TODO Move this check to the envelope loop. *)
  let prefix = '\x00'

  let name =
    "AEAD_AES_256_GCM, "
    ^ "mirage-crypto, key: SHA-256, nonce: 96 bits mirage-crypto-rng"

  let derive_key secret =
    secret
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_raw_string
    |> Mirage_crypto.AES.GCM.of_secret

  (* TODO Memoize keys or otherwise avoid key derivation on every call. *)
  let encrypt_with_nonce secret nonce plaintext associated_data =
    let key = derive_key secret in
    let adata = associated_data in
    let ciphertext =
      Mirage_crypto.AES.GCM.authenticate_encrypt ~key ~nonce ?adata plaintext
    in

    "\x00" ^ nonce ^ ciphertext

  let encrypt ?associated_data ~secret plaintext =
    encrypt_with_nonce secret (Random.random_buffer 12) plaintext
      associated_data

  let test_encrypt ?associated_data ~secret ~nonce plaintext =
    encrypt_with_nonce secret nonce plaintext associated_data

  let decrypt ?associated_data ~secret ciphertext =
    let key = derive_key secret in
    if String.length ciphertext < 14 then
      None
    else if ciphertext.[0] != prefix then
      None
    else
      let adata = associated_data in
      let plaintext =
        Mirage_crypto.AES.GCM.authenticate_decrypt ~key
          ~nonce:(String.sub ciphertext 1 12)
          ?adata
          (String.sub ciphertext 13 (String.length ciphertext - 13))
      in
      plaintext
end

let secrets_field =
  Message.new_field ~name:"dream.secret"
    ~show_value:(fun _secrets -> "[redacted]")
    ()

(* TODO Add warnings about secret length and such. *)
(* TODO Also add warnings about implicit secret generation. However, these
   warnings might be pretty spammy. *)
(* TODO Update examples and docs. *)
let set_secret ?(old_secrets = []) secret =
  let value = secret :: old_secrets in
  fun next_handler request ->
    Message.set_field request secrets_field value;
    next_handler request

let fallback_secrets = lazy [Random.random 32]

let encryption_secret request =
  match Message.field request secrets_field with
  | Some secrets -> List.hd secrets
  | None -> List.hd (Lazy.force fallback_secrets)

let decryption_secrets request =
  match Message.field request secrets_field with
  | Some secrets -> secrets
  | None -> Lazy.force fallback_secrets

let encrypt ?associated_data request plaintext =
  encrypt
    (module AEAD_AES_256_GCM)
    ?associated_data
    (encryption_secret request)
    plaintext

let decrypt ?associated_data request ciphertext =
  decrypt
    (module AEAD_AES_256_GCM)
    ?associated_data
    (decryption_secrets request)
    ciphertext
