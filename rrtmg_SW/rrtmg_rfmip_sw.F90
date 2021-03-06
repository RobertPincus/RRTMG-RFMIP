! This code is part of RRTM for GCM Applications - Parallel (RRTMGP)
!
! Contacts: Robert Pincus and Eli Mlawer
! email:  rrtmgp@aer.com
!
! Copyright 2015-2018,  Atmospheric and Environmental Research and
! Regents of the University of Colorado.  All right reserved.
!
! Use and duplication is permitted under the terms of the
!    BSD 3-clause license, see http://opensource.org/licenses/BSD-3-Clause
! -------------------------------------------------------------------------------------------------
!
! Example program to demonstrate the calculation of shortwave radiative fluxes in clear, aerosol-free skies.
!   The example files come from the Radiative Forcing MIP (https://www.earthsystemcog.org/projects/rfmip/)
!   The large problem (1800 profiles) is divided into blocks
!
! Program is invoked as rrtmgp_rfmip_sw [block_size input_file  coefficient_file upflux_file downflux_file]
!   All arguments are optional but need to be specified in order.
!
! -------------------------------------------------------------------------------------------------
!
! Error checking: Procedures in rte+rrtmgp return strings which are empty if no errors occured
!   Check the incoming string, print it out and stop execution if non-empty
!
subroutine stop_on_err(error_msg)
  use iso_fortran_env, only : error_unit
  character(len=*), intent(in) :: error_msg

  if(error_msg /= "") then
    write (error_unit,*) trim(error_msg)
    write (error_unit,*) "rrtmg_rfmip_sw stopping"
    stop
  end if
end subroutine stop_on_err
! -------------------------------------------------------------------------------------------------
!
! Main program
!
! -------------------------------------------------------------------------------------------------
program rrtmg_rfmip_sw
  ! --------------------------------------------------
  !
  ! Modules for working with rte and rrtmgp
  !
  ! Working precision for real variables
  !
  use mo_rte_kind,           only: wp
  use mo_rfmip_io,           only: read_size, read_and_block_pt, &
    read_and_block_gases_ty, unblock_and_write, &
    read_and_block_lw_bc, read_and_block_sw_bc
  use mo_gas_concentrations, only: ty_gas_concs, get_subset_range
  use rrtmg_sw_rad,          only: rrtmg_sw
  use rrtmg_sw_init,         only: rrtmg_sw_ini

  ! Timing library
  use gptl, only: gptlstart, gptlstop, gptlinitialize, gptlpr, &
    gptlfinalize, gptlsetoption, gptlpercent, gptloverhead

  implicit none
  ! --------------------------------------------------
  !
  ! Local variables
  !
  character(len=132) :: rfmip_file =  'multiple_input4MIPs_radiation_RFMIP_UColorado-RFMIP-1-2_none.nc', &
    flxdn_file = 'rsd_Efx_RRTMG-SW-4-02_rad-irf_r1i1p1f1_gn.nc', flxup_file = 'rsu_Efx_RRTMG-SW-4-02_rad-irf_r1i1p1f1_gn.nc'
  integer :: nargs, ncol, nlay, nexp, nblocks, block_size, ret, &
    dumInt=0, ngpt=16
  logical :: top_at_1
  integer :: i, b, icol, igpt, ilev, nband=1
  real(wp) :: tsi_scale
  character(len=6) :: block_size_char

  character(len=32 ), dimension(:), allocatable :: gases_to_use

  ! block_size, nlay, nblocks
  real(wp), dimension(:,:,:), allocatable :: &
    p_lay, p_lev, t_lay, t_lev, dum3D

  ! block_size, nlay (nlev for HR)
  real(wp), dimension(:,:), allocatable :: &
    swuflx , swdflx, swhr, swuflxc, swdflxc, swhrc, dum2D

  ! gas concentrations (which differ by experiment, and some are
  ! global averages)
  real(wp), dimension(:,:), allocatable :: &
    h2o, co2, o3, n2o, co, ch4, o2, n2

  real(wp), dimension(:,:,:), target, allocatable :: flux_up, flux_dn
  real(wp), dimension(:,:), allocatable :: & ! block_size, nblocks
    surface_albedo, total_solar_irradiance, solar_zenith_angle, &
    emiss_sfc, t_sfc, conc

  logical , dimension(:  ), allocatable :: usecol ! block_size

  type(ty_gas_concs), dimension(:), allocatable  :: gas_conc_array
  character(len=128) :: error_msg

  nargs = command_argument_count()
  if(nargs >= 2) call get_command_argument(2, rfmip_file)
  if(nargs >= 3) call get_command_argument(3, flxup_file)
  if(nargs >= 4) call get_command_argument(4, flxdn_file)

  ! How big is the problem?
  ! Does it fit into blocks of the size we've specified?
  call read_size(rfmip_file, ncol, nlay, nexp)
  if(nargs >= 1) then
    call get_command_argument(1, block_size_char)
    read(block_size_char, '(i6)') block_size
  else
    block_size = ncol
  end if

  if(mod(ncol*nexp, block_size) /= 0 ) &
    call stop_on_err("# of columns doesn't fit evenly into blocks.")
  nblocks = (ncol*nexp)/block_size
  print *, "Doing ",  nblocks, "blocks of size ", block_size

  ! read in RFMIP specs
  call read_and_block_pt(rfmip_file, block_size, p_lay, p_lev, &
    t_lay, t_lev)
  call read_and_block_sw_bc(rfmip_file, block_size, &
    surface_albedo, total_solar_irradiance, solar_zenith_angle)

  ! RRTMG needs surface T
  call read_and_block_lw_bc(rfmip_file, block_size, emiss_sfc, t_sfc)

  ! are we going surface to TOA or TOA to surface?
  top_at_1 = p_lay(1, 1, 1) < p_lay(1, nlay, 1)

  ! RRTMGP won't run with pressure less than its minimum. The top
  ! level in the RFMIP file is set to 10^-3 Pa. Here we pretend the
  ! layer is just a bit less deep. This introduces an error but shows
  ! input sanitizing. Pernak: just going with 10**-3
  if(top_at_1) then
    p_lev(:,1,:) = 1e-3
  else
    p_lev(:,nlay+1,:) = 1e-3
  end if

  allocate(flux_up(block_size, nlay+1, nblocks), &
    flux_dn(block_size, nlay+1, nblocks))
  allocate(usecol(block_size))

  ! RRTMG output arrays
  allocate(swuflx(block_size, nlay+1), swdflx(block_size, nlay+1), &
    swuflxc(block_size, nlay+1), swdflxc(block_size, nlay+1), &
    swhr(block_size, nlay), swhrc(block_size, nlay))

  ! grab concentrations
  call read_and_block_gases_ty(rfmip_file, block_size, &
    gases_to_use, gas_conc_array)

  allocate(h2o(block_size, nlay), co2(block_size, nlay), &
    o3(block_size, nlay), n2o(block_size, nlay), &
    co(block_size, nlay), ch4(block_size, nlay), &
    o2(block_size, nlay), n2(block_size, nlay))

  allocate(dum2D(block_size, nlay+1), dum3D(block_size, nlay, nband))
  dum2D(:,:) = 0._wp
  dum3D(:,:,:) = 0._wp

  ! Initialize timers
  ! Turn on "% of" print
  ret = gptlsetoption (gptlpercent, 1)
  ! Turn off overhead estimate
  ret = gptlsetoption (gptloverhead, 0)
  ret =  gptlinitialize()

  ! Loop over blocks
  call rrtmg_sw_ini(1004.64_wp)
  do i = 1, 32
  do b = 1, nblocks
    error_msg = gas_conc_array(b)%get_vmr('h2o', h2o(:,:))
    error_msg = gas_conc_array(b)%get_vmr('co2', co2(:,:))
    error_msg = gas_conc_array(b)%get_vmr('o3', o3(:,:))
    error_msg = gas_conc_array(b)%get_vmr('n2o', n2o(:,:))
    error_msg = gas_conc_array(b)%get_vmr('co', co(:,:))
    error_msg = gas_conc_array(b)%get_vmr('ch4', ch4(:,:))
    error_msg = gas_conc_array(b)%get_vmr('o2', o2(:,:))
    error_msg = gas_conc_array(b)%get_vmr('n2', n2(:,:))

    usecol(1:block_size) = &
      solar_zenith_angle(:,b) < 90._wp - 2._wp * spacing(90._wp)

    ! RRTMG flux calculation; not sure if my defaults are entirely
    ! correct (e.g., dyofyr, adjes, scon, isolve isolvar; see
    ! rrtmg_sw_rad.f90 doc)
    ! RRTMG inputs have to be surface to TOA

    ret =  gptlstart('RRTMG (SW)')
    call rrtmg_sw(block_size, nlay, dumInt, dumInt , &
      p_lay(:,nlay:1:-1,b)/100.0, p_lev(:,nlay+1:1:-1,b)/100.0, &
      t_lay(:,nlay:1:-1,b), t_lev(:,nlay+1:1:-1,b), t_sfc(:,b), &
      h2o(:,nlay:1:-1), o3(:,nlay:1:-1), co2(:,nlay:1:-1), &
      ch4(:,nlay:1:-1), n2o(:,nlay:1:-1), o2(:,nlay:1:-1), &
      surface_albedo(:,b), surface_albedo(:,b), &
      surface_albedo(:,b), surface_albedo(:,b), &
      cosd(solar_zenith_angle(:,b)), 1._wp, 0, 0._wp, 0, &
      0, 0, 0, dum3D, &
      dum3D, dum3D, dum3D, dum3D, &
      dum3D, dum3D, dum2D, dum2D, &
      dum3D, dum3D, dum3D, dum3D, &
      flux_up(:,:,b), flux_dn(:,:,b), swhr, swuflxc, swdflxc, swhrc)
    ret =  gptlstop('RRTMG (SW)')

    do icol = 1, block_size
      ! zero out dayttime profile fluxes
      if(.not. usecol(icol)) then
        flux_up(icol,:,b)  = 0._wp
        flux_dn(icol,:,b)  = 0._wp
        cycle
      end if

      ! got the 1360.85 from Eli:
      ! https://rrtmgp2.slack.com/archives/D942AU7QE/p1525442449000187
      ! it's also the solar constant used in RRTMG with scon = 0 and
      ! isolvar = 0
      tsi_scale = total_solar_irradiance(icol,b) / 1360.85

      do ilev = 1, nlay+1
        flux_up(iCol, ilev, b) = flux_up(iCol, ilev, b) * tsi_scale
        flux_dn(iCol, ilev, b) = flux_dn(iCol, ilev, b) * tsi_scale
      enddo ! levels
    end do ! columns

  end do ! blocks
  end do
  ! End timers
  ret = gptlpr(block_size)
  ret = gptlfinalize()

  call unblock_and_write(trim(flxup_file), 'rsu', &
    flux_up(:, nlay+1:1:-1, :))
  call unblock_and_write(trim(flxdn_file), 'rsd', &
    flux_dn(:, nlay+1:1:-1, :))

end program rrtmg_rfmip_sw
