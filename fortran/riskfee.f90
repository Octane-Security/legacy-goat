! riskfee.f90 - fee, interest and net-amount calc for one funds-transfer request
! io contract: contracts/records/fortran-fee-io.md
program riskfee
  implicit none

  character(len=20) :: transfer_id
  character(len=3)  :: currency, account_type
  character(len=4)  :: rate_code
  character(len=8)  :: status
  integer :: term_days
  real(kind=8) :: amount, fee, interest, net_amount, rate
  integer(kind=8) :: amount_cents, fee_cents, interest_cents, net_cents

  ! currency and rate_code are consumed to keep record alignment, not used below
  read(*, '(a20,f16.2,a3,a3,i5,a4)') transfer_id, amount, currency, account_type, term_days, rate_code

  if (amount < 0.0d0 .or. amount >= 1.0d13 .or. term_days < 0) then
    status = 'RANGEERR'
    fee = 0.0d0
    interest = 0.0d0
    net_amount = 0.0d0
  else
    if (account_type == 'CHK') then
      rate = 0.0010d0
    else if (account_type == 'SAV') then
      rate = 0.0015d0
    else
      rate = 0.0000d0
    end if

    fee_cents = nint(amount * rate * 100.0d0)
    fee = real(fee_cents, kind=8) / 100.0d0

    ! no accrual formula is defined in the contracts; interest is always zero
    interest = 0.0d0
    interest_cents = nint(interest * 100.0d0, kind=8)

    ! sum in cents so net_amount can't drift off the double-precision grid
    amount_cents = nint(amount * 100.0d0, kind=8)
    net_cents = amount_cents + fee_cents + interest_cents
    net_amount = real(net_cents, kind=8) / 100.0d0

    status = 'OK'
  end if

  write(*, '(a20,3f16.2,a8)') transfer_id, fee, interest, net_amount, status

end program riskfee
