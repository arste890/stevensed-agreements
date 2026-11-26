// StevensED: continue straight to StevensED sign-in (form posts with a CSRF token; a button remains as fallback).
document.addEventListener('DOMContentLoaded', function () {
  var form = document.getElementById('se-sso-form')
  if (form) form.submit()
})
