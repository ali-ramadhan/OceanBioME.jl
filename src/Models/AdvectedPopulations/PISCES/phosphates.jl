#This document contains functions for:
    #PO₄ forcing (eq59)

@inline function (bgc::PISCES)(::Val{:PO₄}, x, y, z, t, P, D, Z, M, Pᶜʰˡ, Dᶜʰˡ, Pᶠᵉ, Dᶠᵉ, Dˢⁱ, DOC, POC, GOC, SFe, BFe, PSi, NO₃, NH₄, PO₄, Fe, Si, CaCO₃, DIC, Alk, O₂, T, PAR, PAR¹, PAR², PAR³, zₘₓₗ, zₑᵤ, Si̅, D_dust) #eq59
    
    γᶻ = bgc.excretion_as_DOM.Z
    σᶻ = bgc.non_assimilated_fraction.Z
    γᴹ = bgc.excretion_as_DOM.M
    σᴹ = bgc.non_assimilated_fraction.M

    bFe = Fe

    #L_day
    ϕ₀ = bgc.latitude
    L_day_param = bgc.length_of_day
    ϕ = get_ϕ(ϕ₀, y)
    L_day = get_L_day(ϕ, t, L_day_param)
    
    #Grazing
    grazingᶻ = get_grazingᶻ(P, D, POC, T, bgc)
    grazingᴹ = get_grazingᴹ(P, D, Z, POC, T, bgc)
    ∑gᶻ = grazingᶻ[1]
    ∑gᴹ = grazingᴹ[1]
    ∑g_FFᴹ = get_∑g_FFᴹ(zₑᵤ, zₘₓₗ, T, POC, GOC, bgc)

    #Gross growth efficiency
    eᶻ = eᴶ(eₘₐₓᶻ, σᶻ, gₚᶻ, g_Dᶻ, gₚₒᶻ, g_zᴹ, N, Fe, P, D, POC, Z, bgc)
    eᴹ =  eᴶ(eₘₐₓᴹ, σᴹ, gₚᴹ, g_Dᴹ, gₚₒᴹ, g_zᴹ,Pᶠᵉ, Dᶠᵉ, SFe, P, D, POC, bgc)

    #Growth rates for phytoplankton
    Lₗᵢₘᴾ = Lᴾ(P, PO₄, NO₃, NH₄, Pᶜʰˡ, Pᶠᵉ, bgc)[1]
    Lₗᵢₘᴰ = Lᴰ(D, PO₄, NO₃, NH₄, Si, Dᶜʰˡ, Dᶠᵉ, Si̅, bgc)[1]
    μᴾ = μᴵ(P, Pᶜʰˡ, PARᴾ, L_day, T, αᴾ, Lₗᵢₘᴾ, zₘₓₗ, zₑᵤ, t_darkᴾ, bgc)
    μᴰ = μᴵ(D, Dᶜʰˡ, PARᴰ, L_day, T, αᴰ, Lₗᵢₘᴰ, zₘₓₗ, zₑᵤ, t_darkᴰ, bgc)

    return γᶻ*(1-eᶻ-σᶻ)*∑gᶻ*Z + γᴹ*(1 - eᴹ - σᴹ)*(∑gᴹ + ∑g_FFᴹ)*M + γᴹ*Rᵤₚ(M, T, bgc) + get_Remin(O₂, NO₃, PO₄, NH₄, DOC, T, bFe, Bact, bgc) + get_Denit(NO₃, PO₄, NH₄, DOC, O₂, T, bFe, Bact, bgc) - μᴾ*P  - μᴰ*D
end